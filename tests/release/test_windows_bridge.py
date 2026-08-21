from __future__ import annotations

import hashlib
import importlib.util
import json
import re
from copy import deepcopy
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "contracts/windows-release-trust.json"
SCRIPT = ROOT / "scripts/verify_windows_bridge.py"


def _module():
    spec = importlib.util.spec_from_file_location("verify_windows_bridge", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _active_contract(tmp_path: Path, *, artifact: bytes = b"one bridge") -> Path:
    value = json.loads(CONTRACT.read_text(encoding="utf-8"))
    value["state"] = "dual_pinned"
    value["legacy"]["bridgeMaximum"] = "0.5.0"
    value["projection"]["minimumVersion"] = "0.5.0"
    value["bridge"].update(
        {
            "selected": True,
            "version": "0.5.0",
            "artifactSha256": hashlib.sha256(artifact).hexdigest(),
            "legacyBundleSha256": hashlib.sha256(b"legacy bundle").hexdigest(),
            "projectionBundleSha256": hashlib.sha256(b"projection bundle").hexdigest(),
        }
    )
    value["activation"]["releaseSelected"] = True
    path = tmp_path / "contract.json"
    path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")
    return path


def test_repository_contract_is_inert_and_exact():
    module = _module()
    value = module.load_contract(CONTRACT)

    assert value["state"] == "legacy_only"
    assert value["bridge"]["selected"] is False
    assert value["activation"]["publicationAuthorized"] is False
    assert value["activation"]["workflowsLocation"] == "workflows-disabled"


def test_dual_bundle_harness_requires_exact_byte_identity(tmp_path, monkeypatch):
    module = _module()
    contract = _active_contract(tmp_path)
    legacy = tmp_path / "legacy.exe"
    projection = tmp_path / "projection.exe"
    legacy.write_bytes(b"one bridge")
    projection.write_bytes(b"different bridge")
    legacy_bundle = tmp_path / "legacy.bundle"
    projection_bundle = tmp_path / "projection.bundle"
    legacy_bundle.write_bytes(b"legacy bundle")
    projection_bundle.write_bytes(b"projection bundle")
    monkeypatch.setattr(module, "_verify_sigstore_bundle", lambda **_kwargs: None)

    with pytest.raises(module.BridgeVerificationError, match="not identical"):
        module.verify_bridge(
            contract,
            legacy_artifact=legacy,
            projection_artifact=projection,
            legacy_bundle=legacy_bundle,
            projection_bundle=projection_bundle,
        )


def test_dual_bundle_harness_binds_both_exact_identities(tmp_path, monkeypatch):
    module = _module()
    contract = _active_contract(tmp_path)
    legacy = tmp_path / "legacy.exe"
    projection = tmp_path / "projection.exe"
    legacy.write_bytes(b"one bridge")
    projection.write_bytes(b"one bridge")
    legacy_bundle = tmp_path / "legacy.bundle"
    projection_bundle = tmp_path / "projection.bundle"
    legacy_bundle.write_bytes(b"legacy bundle")
    projection_bundle.write_bytes(b"projection bundle")
    identities = []
    monkeypatch.setattr(
        module,
        "_verify_sigstore_bundle",
        lambda **kwargs: identities.append((kwargs["issuer"], kwargs["identity"])),
    )

    result = module.verify_bridge(
        contract,
        legacy_artifact=legacy,
        projection_artifact=projection,
        legacy_bundle=legacy_bundle,
        projection_bundle=projection_bundle,
    )

    assert result["networkUsed"] is False
    assert result["published"] is False
    assert identities == [
        (
            module.EXPECTED_ISSUER,
            module.LEGACY_WORKFLOW + "@refs/tags/v0.5.0",
        ),
        (
            module.EXPECTED_ISSUER,
            module.PROJECTION_WORKFLOW + "@refs/tags/v0.5.0",
        ),
    ]


def test_old_identity_is_rejected_past_bridge_maximum(tmp_path):
    module = _module()
    contract = module.load_contract(_active_contract(tmp_path))
    assert not module.candidate_is_trusted(
        contract,
        repository=module.LEGACY_REPOSITORY,
        workflow=module.LEGACY_WORKFLOW,
        tag="v0.5.1",
        version="0.5.1",
        artifact_sha256="a" * 64,
        current_version="0.5.0",
    )


def test_projection_identity_is_rejected_before_transition(tmp_path):
    module = _module()
    contract = module.load_contract(_active_contract(tmp_path))
    assert not module.candidate_is_trusted(
        contract,
        repository=module.PROJECTION_REPOSITORY,
        workflow=module.PROJECTION_WORKFLOW,
        tag="v0.4.9",
        version="0.4.9",
        artifact_sha256="a" * 64,
        current_version="0.4.0",
    )


@pytest.mark.parametrize(
    ("repository", "workflow", "tag"),
    [
        ("AstralDeep/RedirectedProjection", "ignored", "v0.5.0"),
        ("AstralDeep/AstralProjection", "https://github.com/wrong.yml", "v0.5.0"),
        ("AstralDeep/AstralProjection", "projection", "release-0.5.0"),
    ],
)
def test_wrong_repository_workflow_or_tag_is_rejected(
    tmp_path, repository, workflow, tag
):
    module = _module()
    contract = module.load_contract(_active_contract(tmp_path))
    if workflow == "ignored":
        workflow = module.PROJECTION_WORKFLOW
    elif workflow == "projection":
        workflow = module.PROJECTION_WORKFLOW
    assert not module.candidate_is_trusted(
        contract,
        repository=repository,
        workflow=workflow,
        tag=tag,
        version="0.5.0",
        artifact_sha256=contract["bridge"]["artifactSha256"],
        current_version="0.4.0",
    )


def test_equal_or_older_candidate_is_a_downgrade(tmp_path):
    module = _module()
    contract = module.load_contract(_active_contract(tmp_path))
    for version in ("0.4.9", "0.5.0"):
        assert not module.candidate_is_trusted(
            contract,
            repository=module.PROJECTION_REPOSITORY,
            workflow=module.PROJECTION_WORKFLOW,
            tag=f"v{version}",
            version=version,
            artifact_sha256=contract["bridge"]["artifactSha256"],
            current_version="0.5.0",
        )


def test_contract_rejects_wrong_trust_boundary(tmp_path):
    module = _module()
    value = json.loads(CONTRACT.read_text(encoding="utf-8"))
    for field, changed in (
        ("repository", "AstralDeep/renamed-by-redirect"),
        ("workflowIdentity", "https://github.com/wrong/workflow.yml"),
    ):
        candidate = deepcopy(value)
        candidate["legacy"][field] = changed
        path = tmp_path / f"wrong-{field}.json"
        path.write_text(json.dumps(candidate), encoding="utf-8")
        with pytest.raises(module.BridgeVerificationError, match="not exact"):
            module.load_contract(path)


def test_every_copied_workflow_remains_inert_until_activation():
    active = ROOT / ".github/workflows"
    assert not active.exists()
    workflows = sorted((ROOT / "workflows-disabled").glob("*.yml"))
    assert len(workflows) == 9
    job_count = 0
    for workflow in workflows:
        lines = workflow.read_text(encoding="utf-8").splitlines()
        jobs_index = lines.index("jobs:")
        starts = [
            index
            for index, line in enumerate(lines[jobs_index + 1 :], jobs_index + 1)
            if re.fullmatch(r"  [A-Za-z0-9_-]+:", line)
        ]
        for position, start in enumerate(starts):
            end = starts[position + 1] if position + 1 < len(starts) else len(lines)
            block = "\n".join(lines[start:end])
            assert "if: ${{ false }}" in block, workflow.name
        job_count += len(starts)
    assert job_count == 19
