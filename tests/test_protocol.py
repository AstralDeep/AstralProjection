"""Tests for src/astralprojection/protocol.py: canonicalization, metadata validation,
client drift-guard/voice-fixture consumption, transformation-record source binding,
and that release workflows stay inert and dependency-locked.
"""

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
ACTIVE_WORKFLOWS = ROOT / ".github" / "workflows"
SOURCE_REPOSITORY_ENV = "ASTRALDEEP_SOURCE_REPO"
VOICE_065_FIXTURE = ROOT / "contracts" / "fixtures" / "voice_065" / "client_conformance.json"
VOICE_075_FIXTURE = (
    ROOT / "contracts" / "fixtures" / "voice_075" / "client_local_conformance.json"
)
VOICE_065_SHA256 = "bc98077594fa8d51dd664fadefaa48cf596a94e7fb2a961a972dbabca4f02143"


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
        assert "contracts/ui_protocol.json" in text or '"contracts" / "ui_protocol.json"' in text, path
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
        assert "contracts/fixtures/voice_075/client_local_conformance.json" in text, path
        assert "backend/tests/fixtures/voice_065" not in text, path


def test_voice_075_contract_is_strict_complete_and_preserves_remote_v1_bytes() -> None:
    document = json.loads(MANIFEST.read_text(encoding="utf-8"))
    local = document["frame_contracts"]["voice_075"]

    assert hashlib.sha256(VOICE_065_FIXTURE.read_bytes()).hexdigest() == VOICE_065_SHA256
    assert local["remote_v1_byte_invariant"] == {
        "fixture": "contracts/fixtures/voice_065/client_conformance.json",
        "sha256": VOICE_065_SHA256,
    }
    assert local["schema_version"] == "2"
    assert local["rest_contract"] == "voice-rest/v2-client-local"
    assert local["local_frame_contract"] == "client_local/v1"
    assert local["additional_fields"] is False
    assert local["requirements"] == {
        "session_contract": "voice-rest/v2-client-local",
        "local_frame_contract": "client_local/v1",
        "configured_locale": "en-US",
        "recognition_must_be_local": True,
        "synthesis_must_be_local": True,
        "installation_policy": "explicit_user_action_only",
        "requirement_revision": 1,
        "max_final_unicode_scalars": 8000,
        "max_announcement_utf8_bytes": 600,
        "announcement_ttl_seconds": 10,
        "echo_suppression_milliseconds": 500,
    }

    common = {
        "schema_version",
        "speech_backend",
        "device_id",
        "connection_generation",
        "session_id",
        "generation",
        "speech_revision",
    }
    expected_fields = {
        "voice_local_ready": common
        | {
            "type",
            "contract",
            "transport",
            "configured_locale",
            "full_duplex",
            "has_microphone",
            "has_audio_output",
            "microphone_permission",
            "recognition_permission",
            "recognition_processing",
            "recognition_locale",
            "recognition_installation",
            "synthesis_processing",
            "synthesis_locale",
            "client_sequence",
        },
        "voice_local_session_ready": common
        | {
            "type",
            "contract",
            "transport",
            "configured_locale",
            "chat_id",
            "chat_context_revision",
            "applied_chat_context_revision",
            "foreground_active",
            "microphone_enabled",
            "speech_muted",
            "lease_expires_at",
        },
        "voice_local_recognition_started": common
        | {
            "type",
            "client_turn_id",
            "chat_id",
            "chat_context_revision",
            "recognition_sequence",
        },
        "voice_local_turn_bound": common
        | {
            "type",
            "client_turn_id",
            "turn_id",
            "submission_id",
            "request_generation",
            "chat_id",
            "chat_context_revision",
            "recognition_sequence",
            "binding_expires_at",
        },
        "voice_local_final": common
        | {
            "type",
            "client_turn_id",
            "turn_id",
            "submission_id",
            "request_generation",
            "chat_id",
            "chat_context_revision",
            "recognition_sequence",
            "final",
            "recognized_locale",
            "text",
            "text_digest_sha256",
        },
        "voice_local_recognition_failed": common
        | {
            "type",
            "client_turn_id",
            "turn_id",
            "submission_id",
            "request_generation",
            "chat_id",
            "chat_context_revision",
            "recognition_sequence",
            "reason",
        },
        "voice_local_final_rejected": common
        | {
            "type",
            "client_turn_id",
            "turn_id",
            "submission_id",
            "request_generation",
            "chat_id",
            "chat_context_revision",
            "recognition_sequence",
            "reason",
            "retry_policy",
            "occurred_at",
        },
        "voice_local_announcement": common
        | {
            "type",
            "announcement_id",
            "announcement_sequence",
            "turn_id",
            "kind",
            "output_policy",
            "locale",
            "text",
            "text_digest_sha256",
            "expires_at",
            "foreground_required",
            "mute_revision",
            "consent_revision",
        },
        "voice_local_playout_event": common
        | {
            "type",
            "announcement_id",
            "announcement_sequence",
            "turn_id",
            "kind",
            "phase",
            "client_sequence",
            "observed_at",
        },
    }
    actual_fields = {
        name: set(fields) for name, fields in local["exact_frame_fields"].items()
    }
    assert actual_fields == expected_fields
    assert all("speech_revision" in fields for fields in actual_fields.values())
    assert local["optional_frame_fields"] == {
        "voice_local_playout_event": ["reason"],
    }
    assert {
        name: set(fields) for name, fields in local["exact_rest_fields"].items()
    } == {
        "voice_capability_v2": {
            "schema_version",
            "speech_backend",
            "status",
            "reason",
            "checked_at",
            "expires_at",
            "supported_transports",
            "requirements",
        },
        "client_local_capability": {
            "contract",
            "transport",
            "configured_locale",
            "full_duplex",
            "has_microphone",
            "has_audio_output",
            "microphone_permission",
            "recognition_permission",
            "recognition_processing",
            "recognition_locale",
            "recognition_installation",
            "synthesis_processing",
            "synthesis_locale",
        },
    }
    assert local["optional_rest_fields"] == {
        "voice_capability_v2": ["retry_after_seconds"],
    }
    assert set(local["closed_reasons"]) == {
        "altered_local_final",
        "announcement_consent_invalid",
        "announcement_invalid",
        "announcement_stale_sequence",
        "announcement_suppressed_background",
        "announcement_suppressed_muted",
        "asr_unavailable",
        "authentication_required",
        "backend_mismatch",
        "backend_selection_invalid",
        "capacity_exhausted",
        "client_contract_upgrade_required",
        "client_readiness_required",
        "duplicate_local_final",
        "feature_disabled",
        "internal_error",
        "invalid_binding",
        "local_announcement_expired",
        "local_audio_interrupted",
        "local_capture_not_ready",
        "local_engine_lost",
        "local_final_empty",
        "local_final_malformed",
        "local_final_oversized",
        "local_language_download_required",
        "local_language_install_failed",
        "local_language_installing",
        "local_language_mismatch",
        "local_processing_not_guaranteed",
        "local_recognition_cancelled",
        "local_recognition_failed",
        "local_recognition_locale_unavailable",
        "local_recognition_unavailable",
        "local_session_not_ready",
        "local_synthesis_failed",
        "local_synthesis_locale_unavailable",
        "local_synthesis_unavailable",
        "microphone_permission_denied",
        "microphone_permission_not_determined",
        "no_audio_output",
        "no_microphone",
        "ready",
        "speech_recognition_permission_denied",
        "speech_recognition_permission_not_determined",
        "stale_chat_context",
        "stale_connection",
        "stale_local_turn",
        "stale_session",
        "stale_speech_revision",
        "stopped_by_user",
        "takeover_required",
        "tts_unavailable",
        "unsupported_speech_backend",
        "worker_unavailable",
    }


def test_voice_075_fixture_vectors_use_closed_dispositions_and_reject_extra_keys() -> None:
    document = json.loads(MANIFEST.read_text(encoding="utf-8"))
    local = document["frame_contracts"]["voice_075"]
    fixture = json.loads(VOICE_075_FIXTURE.read_text(encoding="utf-8"))
    vectors = fixture["vectors"]

    assert fixture["format"] == "astral.voice.client-local-conformance/v1"
    assert fixture["schema_version"] == "2"
    assert fixture["contract"] == "client_local/v1"
    assert {vector["category"] for vector in vectors} == {
        "supported",
        "unavailable",
        "stale",
        "denial",
        "local_final",
        "announcement",
        "playout",
        "rejected_final",
    }
    assert len(vectors) == 15
    assert len({vector["id"] for vector in vectors}) == len(vectors)
    closed_dispositions = set(local["required_dispositions"])
    assert closed_dispositions == set(fixture["closed_dispositions"])
    assert {
        vector["expected_disposition"]
        for vector in vectors
        if "expected_disposition" in vector
    } <= closed_dispositions

    exact_shapes = {**local["exact_frame_fields"], **local["exact_rest_fields"]}
    mutation_ops = {"add", "replace", "remove", "repeat"}

    def assert_exact_keys(payload: dict[str, object], expected: set[str]) -> None:
        assert set(payload) == expected

    for vector in vectors:
        if "payload" not in vector:
            assert vector["category"] == "rejected_final"
            assert "expected_disposition" not in vector
            assert vector["base_vector"] in {item["id"] for item in vectors}
            assert vector["expected_error"] in local["closed_reasons"]
            for mutation in vector["mutations"]:
                assert set(mutation) <= {"op", "path", "value", "count"}
                assert mutation["op"] in mutation_ops
                assert mutation["path"].startswith("/")
            continue
        payload = vector["payload"]
        exact = set(exact_shapes[vector["shape"]])
        assert_exact_keys(payload, exact)
        with pytest.raises(AssertionError):
            assert_exact_keys({**payload, "unexpected": "forbidden"}, exact)


def test_voice_075_scalar_limit_vectors_are_boundary_exact_and_digest_bound() -> None:
    fixture = json.loads(VOICE_075_FIXTURE.read_text(encoding="utf-8"))
    vectors = {vector["id"]: vector for vector in fixture["vectors"]}

    def materialize(vector: dict[str, object]) -> dict[str, object]:
        payload = dict(vectors[vector["base_vector"]]["payload"])
        for mutation in vector["mutations"]:
            assert mutation["op"] == "repeat"
            path = mutation["path"].lstrip("/")
            payload[path] = mutation["value"] * mutation["count"]
        return payload

    positive_ids = (
        "L-P05-final-ascii-scalar-boundary",
        "L-P06-final-supplementary-scalars",
        "L-P07-final-combining-scalars",
        "L-P08-final-zwj-scalars",
    )
    negative_ids = (
        "L-N04-final-over-ascii-scalar-limit",
        "L-N05-final-supplementary-over-scalar-limit",
        "L-N06-final-combining-over-scalar-limit",
        "L-N07-final-zwj-over-scalar-limit",
    )
    for identifier in positive_ids:
        payload = vectors[identifier]["payload"]
        text = payload["text"]
        assert len(text) <= 8000
        assert payload["text_digest_sha256"] == hashlib.sha256(text.encode("utf-8")).hexdigest()
    for identifier in negative_ids:
        text = materialize(vectors[identifier])["text"]
        assert len(text) > 8000
        assert 8001 <= len(text) <= 16002


def test_runtime_manifests_bind_exact_owning_dependency_inventory() -> None:
    immutable_manifests = {
        "tooling/python-ci/requirements.lock.txt": (
            "ed268e071ad98432ae418a6ac54189f64ae26e02049b9a7c49bbceffaf820171"
        ),
        "tooling/web-ci/package.json": (
            "e0b919dea803f0f01374aa3f3cf70578a5a184444e79766cec7fef4d103e0bbd"
        ),
        "tooling/web-ci/package-lock.json": (
            "1c73e51ca61a7aaeae421e76e4cf54e6e8f35b96a27b64a5bdcec5a531137531"
        ),
        "windows-client/requirements.in": (
            "697e2bc0786468f3621d2e043af81d6721e6734816cbe00eca7901958921a58f"
        ),
        "windows-client/requirements.txt": (
            "d301d1e3a1b523fda5c1488693cf9a7a4336504c0d168bd0f4e220c8b0302c95"
        ),
        "windows-client/requirements-release.lock.txt": (
            "cd04dd23361ee769f57ea1d046b0b5e10aa50bb41ebe65c4683d7518c9e9a079"
        ),
        "windows-client/deployment/runtime-lock-contract.json": (
            "24a819186b94951bba81e2f280aa00258cf99cbf02b0363a9e5bada1f8a62bd8"
        ),
        "android-client/buildscript-gradle.lockfile": (
            "9e0750c539a1715561bb7018f3f24010f2542a7400b953abc4958959c9616750"
        ),
        "android-client/settings-gradle.lockfile": (
            "5e2d075903b5cd264613e7538c7c51b1484fe2ed489d4ead3e6b4ba0cf3911c4"
        ),
        "android-client/app/gradle.lockfile": (
            "dc9eaa61e7e5dec01334bf04642b03304e41d5ef321203ffdb8e999f32b45c35"
        ),
        "android-client/core/gradle.lockfile": (
            "aee1fb50d70d15c9c7be9def38101135e607b42ba440477c6a8e3043333cfc49"
        ),
        "android-client/gradle/libs.versions.toml": (
            "a93ad97e4fb1ab31546fbe0d2b3db0a69eb0578d01e7e134cbad2f9652e41d5c"
        ),
        "apple-clients/AstralApp/AstralApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved": (
            "5cf70218d493aa617c2a4f33831214104e76b93eb70d23ef924a3039afbfcc73"
        ),
        "pyproject.toml": (
            "e4384cda1aec04d50a46d2134a6d9524b3a3ec3d1000e4d052a437cf44741e3b"
        ),
    }
    assert set(immutable_manifests) == {
        "android-client/app/gradle.lockfile",
        "android-client/buildscript-gradle.lockfile",
        "android-client/core/gradle.lockfile",
        "android-client/gradle/libs.versions.toml",
        "android-client/settings-gradle.lockfile",
        "apple-clients/AstralApp/AstralApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "pyproject.toml",
        "tooling/python-ci/requirements.lock.txt",
        "tooling/web-ci/package-lock.json",
        "tooling/web-ci/package.json",
        "windows-client/deployment/runtime-lock-contract.json",
        "windows-client/requirements-release.lock.txt",
        "windows-client/requirements.in",
        "windows-client/requirements.txt",
    }
    for relative, expected in immutable_manifests.items():
        assert hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() == expected, relative

    project = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert 'dependencies = ["astralprims==0.4.0"]' in project
    apple = (ROOT / "apple-clients" / "AstralCore" / "Package.swift").read_text(
        encoding="utf-8"
    )
    assert ".package(" not in apple


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

    relative = link.relative_to(ROOT).as_posix()
    assert _index_modes(ROOT)[relative] == "120000"
    target = os.readlink(link) if link.is_symlink() else link.read_text(encoding="utf-8")
    assert target.replace("\\", "/").strip() == (
        "../../../../../contracts/fixtures/voice_065"
    )
    assert (link.parent / target.strip()).resolve(strict=True) == (
        ROOT / "contracts" / "fixtures" / "voice_065"
    ).resolve()


def test_release_workflows_are_explicitly_inert_read_only_and_projection_owned() -> None:
    workflows = sorted(WORKFLOWS.glob("*.yml"))
    assert len(workflows) == 6
    assert {path.name for path in ACTIVE_WORKFLOWS.glob("*.yml")} == {
        "android-ci.yml",
        "apple-ci.yml",
        "ci.yml",
        "pr-ci-notifications.yml",
        "pr-triage.yml",
    }

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
    assert len(paths) == 389
    assert sum(entry.get("resultStatus") == "removed" for entry in record["entries"]) == 20

    moved_workflows = {
        entry["path"]: [result["path"] for result in entry.get("resultPaths", [])]
        for entry in record["entries"]
        if entry.get("resultPaths")
    }
    assert moved_workflows == {
        "workflows-disabled/android-ci.yml": [".github/workflows/android-ci.yml"],
        "workflows-disabled/apple-ci.yml": [".github/workflows/apple-ci.yml"],
    }

    changed_paths = _changed_extraction_paths(
        extraction["entries"],
        ROOT,
        _index_modes(ROOT),
    )
    assert set(paths) == changed_paths, (
        f"unledgered imported changes: {sorted(changed_paths - set(paths))}; "
        f"ledger entries without imported changes: {sorted(set(paths) - changed_paths)}"
    )
    assert len(extracted) - len(changed_paths) == 130

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
            for result in entry.get("resultPaths", []):
                relative = Path(result["path"])
                assert not relative.is_absolute()
                result_path = ROOT / relative
                result_path.resolve(strict=True).relative_to(ROOT.resolve(strict=True))
                assert result["sha256"] == hashlib.sha256(
                    _current_bytes(result_path)
                ).hexdigest()
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
