from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
import stat
import subprocess

import pytest

import astralprojection
from astralprojection import protocol

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "contracts" / "ui_protocol.json"
TRANSFORMATIONS = ROOT / "provenance" / "transformations.json"
WORKFLOWS = ROOT / "workflows-disabled"
SOURCE_REPOSITORY_ENV = "ASTRALDEEP_SOURCE_REPO"


def _canonical_bytes(document: object) -> bytes:
    return json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _current_bytes(path: Path) -> bytes:
    if path.is_symlink():
        return os.readlink(path).replace("\\", "/").encode("utf-8")
    return path.read_bytes()


def _git_blob_id(content: bytes) -> str:
    header = f"blob {len(content)}\0".encode("ascii")
    return hashlib.sha1(header + content, usedforsecurity=False).hexdigest()


def _index_modes(repository_root: Path) -> dict[str, str]:
    completed = subprocess.run(
        ["git", "ls-files", "--stage", "-z"],
        cwd=repository_root,
        check=True,
        capture_output=True,
    )
    modes: dict[str, str] = {}
    for record in completed.stdout.split(b"\0"):
        if not record:
            continue
        metadata, separator, raw_path = record.partition(b"\t")
        if not separator:
            raise AssertionError("malformed git index record")
        mode = metadata.split(b" ", 1)[0].decode("ascii")
        modes[raw_path.decode("utf-8").replace("\\", "/")] = mode
    return modes


def _current_mode(path: Path, relative: str, index_modes: dict[str, str]) -> str | None:
    if path.is_symlink():
        return "120000"
    if not path.exists():
        return None
    if os.name != "nt":
        return "100755" if path.stat().st_mode & stat.S_IXUSR else "100644"
    return index_modes.get(relative)


def _changed_extraction_paths(
    entries: list[dict[str, object]],
    repository_root: Path,
    index_modes: dict[str, str],
) -> set[str]:
    changed: set[str] = set()
    for imported in entries:
        relative = str(imported["destinationPath"])
        current = repository_root / relative
        mode = _current_mode(current, relative, index_modes)
        if mode is None or mode != imported["mode"]:
            changed.add(relative)
            continue
        if _git_blob_id(_current_bytes(current)) != imported["blob"]:
            changed.add(relative)
    return changed


def _selected_source_tuples(
    source_repository: Path,
    source_commit: str,
    selection_roots: list[str],
) -> dict[str, tuple[str, str, int]]:
    selected: dict[str, tuple[str, str, int]] = {}
    for selection_root in selection_roots:
        completed = subprocess.run(
            [
                "git",
                "ls-tree",
                "-r",
                "-l",
                "-z",
                "--full-tree",
                source_commit,
                "--",
                selection_root,
            ],
            cwd=source_repository,
            check=True,
            capture_output=True,
        )
        records = [record for record in completed.stdout.split(b"\0") if record]
        assert records, f"selection root did not resolve at source commit: {selection_root}"
        for record in records:
            metadata, separator, raw_path = record.partition(b"\t")
            assert separator, f"malformed ls-tree record for {selection_root}"
            mode, object_type, blob, size = metadata.split()
            assert object_type == b"blob"
            path = raw_path.decode("utf-8")
            source_tuple = (mode.decode("ascii"), blob.decode("ascii"), int(size))
            previous = selected.setdefault(path, source_tuple)
            assert previous == source_tuple
    return selected


def test_protocol_facade_exports_authoritative_version_digest_and_path() -> None:
    document = json.loads(MANIFEST.read_text(encoding="utf-8"))
    expected_digest = hashlib.sha256(_canonical_bytes(document)).hexdigest()

    assert protocol.protocol_manifest_path().resolve() == MANIFEST.resolve()
    assert protocol.read_protocol_manifest() == document
    assert protocol.UI_PROTOCOL_VERSION == str(document["version"]) == "1"
    assert protocol.UI_PROTOCOL_SHA256 == expected_digest
    assert astralprojection.UI_PROTOCOL_VERSION == protocol.UI_PROTOCOL_VERSION
    assert astralprojection.UI_PROTOCOL_SHA256 == protocol.UI_PROTOCOL_SHA256
    assert astralprojection.protocol_manifest_path().resolve() == MANIFEST.resolve()


def test_protocol_canonicalization_is_whitespace_and_key_order_independent() -> None:
    left = {"version": 1, "nested": {"z": [2, 1], "a": True}}
    right = json.loads('{ "nested" : { "a" : true, "z" : [2, 1] }, "version" : 1 }')

    assert protocol.canonical_manifest_bytes(left) == _canonical_bytes(right)


@pytest.mark.parametrize("document", [[], {}, {"version": True}, {"version": 0}, {"version": " "}])
def test_protocol_metadata_rejects_invalid_documents(document: object) -> None:
    with pytest.raises(ValueError, match="manifest|version"):
        protocol.manifest_metadata(document)


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ("[]", "JSON object"),
        ('{"version": NaN}', "non-finite"),
    ],
)
def test_protocol_reader_fails_closed_on_invalid_json_documents(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    payload: str,
    message: str,
) -> None:
    manifest = tmp_path / "ui_protocol.json"
    manifest.write_text(payload, encoding="utf-8")
    monkeypatch.setattr(protocol, "protocol_manifest_path", lambda: manifest)

    with pytest.raises(ValueError, match=message):
        protocol.read_protocol_manifest()


def test_all_client_drift_guards_use_the_standalone_contract() -> None:
    guarded_files = [
        ROOT / "windows-client" / "tests" / "test_protocol_manifest.py",
        ROOT / "windows-client" / "tests" / "test_renderer.py",
        ROOT
        / "android-client"
        / "app"
        / "src"
        / "test"
        / "kotlin"
        / "com"
        / "personalailabs"
        / "astraldeep"
        / "app"
        / "render"
        / "VocabularyParityTest.kt",
        ROOT
        / "android-client"
        / "core"
        / "src"
        / "test"
        / "kotlin"
        / "com"
        / "personalailabs"
        / "astraldeep"
        / "core"
        / "protocol"
        / "ProtocolManifestTest.kt",
        ROOT
        / "apple-clients"
        / "AstralCore"
        / "Tests"
        / "AstralCoreTests"
        / "ManifestDriftTests.swift",
    ]

    for path in guarded_files:
        text = path.read_text(encoding="utf-8")
        assert "contracts/ui_protocol.json" in text, path
        assert "backend/shared/ui_protocol.json" not in text, path

    apple = guarded_files[-1].read_text(encoding="utf-8")
    assert "XCTSkip" not in apple
    assert "package checked out standalone" not in apple


def test_all_client_voice_fixture_consumers_use_the_standalone_contract() -> None:
    fixture_consumers = [
        ROOT / "windows-client" / "tests" / "e2e_voice_065.py",
        ROOT / "android-client" / "app" / "build.gradle.kts",
        ROOT
        / "android-client"
        / "core"
        / "src"
        / "test"
        / "kotlin"
        / "com"
        / "personalailabs"
        / "astraldeep"
        / "core"
        / "protocol"
        / "VoiceContract065Test.kt",
        ROOT / "apple-clients" / "AstralCore" / "Package.swift",
    ]

    for path in fixture_consumers:
        text = path.read_text(encoding="utf-8")
        assert "contracts/fixtures/voice_065/client_conformance.json" in text, path
        assert "backend/tests/fixtures/voice_065" not in text, path


def test_apple_fixture_link_targets_the_standalone_fixture_contract() -> None:
    link = (
        ROOT
        / "apple-clients"
        / "AstralCore"
        / "Tests"
        / "AstralCoreTests"
        / "Fixtures"
        / "voice_065"
    )

    assert link.is_symlink()
    assert os.readlink(link).replace("\\", "/") == ("../../../../../contracts/fixtures/voice_065")
    assert link.resolve(strict=True) == (ROOT / "contracts" / "fixtures" / "voice_065").resolve()


def test_disabled_workflows_are_explicitly_inert_read_only_and_projection_owned() -> None:
    workflows = sorted(WORKFLOWS.glob("*.yml"))
    assert len(workflows) == 9

    for path in workflows:
        text = path.read_text(encoding="utf-8")
        assert path.parent.name == "workflows-disabled"
        assert re.search(r"(?m)^permissions:\n  contents: read(?:\s|$)", text), path
        assert not re.search(r"(?m)^\s+[A-Za-z0-9_-]+:\s*write(?:\s|#|$)", text), path
        assert not re.search(r"\bsecrets?\b", text, flags=re.IGNORECASE), path
        assert "AstralDeep/AstralDeep" not in text, path
        assert "backend/shared/ui_protocol.json" not in text, path
        assert "backend/tests/fixtures/voice_065" not in text, path

        jobs = text.split("\njobs:\n", 1)
        assert len(jobs) == 2, path
        job_lines = jobs[1].splitlines()
        starts = [
            index
            for index, line in enumerate(job_lines)
            if re.fullmatch(r"  [A-Za-z0-9_-]+:", line)
        ]
        assert starts, path
        for position, start in enumerate(starts):
            end = starts[position + 1] if position + 1 < len(starts) else len(job_lines)
            block = job_lines[start:end]
            assert "    if: ${{ false }}" in block, (path, job_lines[start])


def test_disabled_apple_release_uses_protected_monotonic_build_number() -> None:
    text = (WORKFLOWS / "apple-release.yml").read_text(encoding="utf-8")

    assert "environment: apple-release" in text
    assert "${{ vars.ASTRAL_APPLE_BUILD_NUMBER_BASE }}" in text
    assert "${{ vars.ASTRAL_APPLE_LAST_SUBMITTED_BUILD }}" in text
    assert "python3 scripts/apple_build_number.py" in text
    assert text.count('CURRENT_PROJECT_VERSION="$APPLE_BUILD_NUMBER"') == 2
    assert 'CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER"' not in text


def test_transformation_record_binds_imported_sources_to_current_bytes() -> None:
    extraction = json.loads((ROOT / "provenance" / "extraction.json").read_text("utf-8"))
    extracted = {entry["destinationPath"]: entry for entry in extraction["entries"]}
    record = json.loads(TRANSFORMATIONS.read_text(encoding="utf-8"))

    assert record["format"] == "astral.extraction-transformations/v1"
    assert record["sourceManifestSha256"] == extraction["manifestSha256"]
    paths = [entry["path"] for entry in record["entries"]]
    assert paths == sorted(paths)
    assert len(paths) == len(set(paths))
    assert len(extraction["entries"]) == 519
    assert len(paths) == 51
    assert sum(entry.get("resultStatus") == "removed" for entry in record["entries"]) == 14

    changed_paths = _changed_extraction_paths(
        extraction["entries"],
        ROOT,
        _index_modes(ROOT),
    )
    assert set(paths) == changed_paths, (
        f"unledgered imported changes: {sorted(changed_paths - set(paths))}; "
        f"ledger entries without imported changes: {sorted(set(paths) - changed_paths)}"
    )
    assert len(extracted) - len(changed_paths) == 468

    for entry in record["entries"]:
        path = entry["path"]
        imported = extracted[path]
        assert entry["sourcePath"] == imported["sourcePath"]
        assert entry["sourceBlob"] == imported["blob"]
        assert entry["sourceMode"] == imported["mode"]
        current = ROOT / path
        if entry.get("resultStatus") == "removed":
            assert not current.exists() and not current.is_symlink()
            assert "resultSha256" not in entry
            assert re.fullmatch(r"T\d{3}(?:/T\d{3})*", entry["task"])
            assert entry["reason"]
            continue
        assert entry.get("resultStatus", "modified") == "modified"
        assert current.exists() or current.is_symlink()
        assert entry["resultSha256"] == hashlib.sha256(_current_bytes(current)).hexdigest()
        assert re.fullmatch(r"T\d{3}(?:/T\d{3})*", entry["task"])
        assert entry["reason"]


def test_extraction_selection_roots_replay_every_immutable_source_tuple() -> None:
    raw_source_repository = os.environ.get(SOURCE_REPOSITORY_ENV)
    if not raw_source_repository:
        pytest.skip(f"{SOURCE_REPOSITORY_ENV} is required for immutable-source replay")
    source_repository = Path(raw_source_repository).resolve(strict=True)
    extraction = json.loads((ROOT / "provenance" / "extraction.json").read_text("utf-8"))
    source = extraction["source"]

    tree = subprocess.run(
        ["git", "show", "-s", "--format=%T", source["commit"]],
        cwd=source_repository,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    assert tree == source["tree"]

    expected = {
        entry["sourcePath"]: (entry["mode"], entry["blob"], entry["bytes"])
        for entry in extraction["entries"]
    }
    assert len(expected) == len(extraction["entries"]) == 519
    actual = _selected_source_tuples(
        source_repository,
        source["commit"],
        extraction["selectionRoots"],
    )
    assert actual == expected

    digest_document = dict(extraction)
    recorded_digest = digest_document.pop("manifestSha256")
    assert hashlib.sha256(_canonical_bytes(digest_document)).hexdigest() == recorded_digest


@pytest.mark.parametrize("mutation", ["modified", "removed"])
def test_changed_extraction_inventory_detects_unledgered_bytes_and_removals(
    tmp_path: Path,
    mutation: str,
) -> None:
    original = b"immutable source bytes\n"
    imported = {
        "destinationPath": "imported.txt",
        "blob": _git_blob_id(original),
        "mode": "100644",
    }
    current = tmp_path / "imported.txt"
    if mutation == "modified":
        current.write_bytes(b"locally changed bytes\n")

    changed = _changed_extraction_paths([imported], tmp_path, {"imported.txt": "100644"})

    assert changed == {"imported.txt"}
    assert changed - set() == {"imported.txt"}
