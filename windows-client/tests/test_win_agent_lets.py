from __future__ import annotations

import hashlib
import json
import time
from dataclasses import replace
from pathlib import Path

import pytest

from lets.canonical import b64url_encode, canonical_digest, canonical_json
from lets.crypto import Ed25519Signer
from lets.manifest import (
    ClusterManifest,
    ManifestPublicKey,
    ManifestSignature,
    WardenManifest,
)
from lets.policy import MachineSpec, PolicySpec, ResourceDimension, TransitionSpec
from lets.models import Receipt

from win_agent import agent
from win_agent import lets_executor as executor


@pytest.fixture(autouse=True)
def _reset_executor():
    agent._reset_protected_executor_for_tests()
    yield
    agent._reset_protected_executor_for_tests()


def _signed_manifest():
    resources = tuple(
        ResourceDimension(name, "count")
        for name in ("read", "write", "search", "system", "files", "execute")
    )
    transitions = tuple(
        TransitionSpec(
            name=transition,
            source="ready",
            target="ready",
            cost=tuple(1 if index == dimension else 0 for index in range(6)),
            capability=capability,
        )
        for _scope, capability, transition, dimension in executor._SCOPE_BINDINGS
    )
    policy = PolicySpec(
        policy_id="astral-tools",
        policy_version="v1",
        dimensions=resources,
        machine=MachineSpec(
            machine_id="astral-tool-effects",
            initial_state="ready",
            transitions=transitions,
        ),
        max_lease_ttl_ns=60_000_000_000,
        receipt_ttl_ns=30_000_000_000,
        max_clock_uncertainty_ns=1_000_000_000,
        transfer_gap_window=64,
    )
    warden = Ed25519Signer.generate("warden-a")
    operator = Ed25519Signer.generate("operator-a")
    manifest = ClusterManifest(
        tenant_id="tenant-a",
        envelope_id="envelope-a",
        config_epoch=1,
        created_at="2026-08-14T00:00:00Z",
        resources=resources,
        initial_budget=(100, 100, 100, 100, 100, 100),
        wardens=(
            WardenManifest(
                warden_id=warden.warden_id,
                peer_endpoint="https://warden-a.example",
                client_endpoint="https://warden-a.example",
                initial_share=(100, 100, 100, 100, 100, 100),
                keys=(
                    ManifestPublicKey(
                        warden.key_id,
                        warden.public_key_bytes,
                    ),
                ),
                extensions={},
            ),
        ),
        policies=(policy,),
        extensions={},
    )
    manifest = replace(
        manifest,
        signatures=(
            ManifestSignature(
                operator.key_id,
                operator.sign(canonical_json(manifest.unsigned_dict())),
            ),
        ),
    )
    return manifest, policy, warden, operator


def _environment(tmp_path):
    manifest, policy, warden, operator = _signed_manifest()
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest.to_dict(), sort_keys=True), encoding="utf-8"
    )
    operator_path = tmp_path / "operators.json"
    operator_path.write_text(
        json.dumps(
            {
                "api_version": executor.OPERATOR_TRUST_TYPE,
                "threshold": 1,
                "keys": [
                    {
                        "key_id": operator.key_id,
                        "algorithm": "Ed25519",
                        "public_key": b64url_encode(operator.public_key_bytes),
                    }
                ],
            },
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    database = tmp_path / "replay"
    authority = tmp_path / "authority"
    database.mkdir()
    authority.mkdir()
    values = {
        "ASTRAL_ENV": "production",
        "FF_LETS_EXTERNAL_WARDEN": "1",
        "LETS_MODE": "enforce",
        "LETS_SIGNED_TRUST_MANIFEST": str(manifest_path),
        "LETS_MANIFEST_OPERATOR_KEYS_FILE": str(operator_path),
        "LETS_WARDEN_ID": warden.warden_id,
        "LETS_TENANT_ID": manifest.tenant_id,
        "LETS_ENVELOPE_ID": manifest.envelope_id,
        "LETS_POLICY_DIGEST": policy.digest,
        "LETS_MACHINE_DIGEST": policy.machine.digest,
        "LETS_EXECUTOR_INSTANCE_ID": "windows-executor-a",
        "LETS_EXECUTOR_DB_ROOT": str(database),
        "LETS_EXECUTOR_AUTHORITY_ROOT": str(authority),
        "ASTRAL_AUTHORITY_OWNER_ID": "owner-a",
        "ASTRAL_AUTHORITY_BINDING_ID": "binding-a",
        "ASTRAL_AUTHORITY_LEASE_ID": "lease-a",
        "ASTRAL_AUTHORITY_LINEAGE_ID": "lineage-a",
        "ASTRAL_RUNTIME_ID": "runtime-a",
        "ASTRAL_RUNTIME_GENERATION": "1",
    }
    return values, manifest, policy, warden


def _permit(manifest, policy, warden, *, arguments):
    nonce = "ab" * 16
    context = {
        "type": executor.EVIDENCE_TYPE,
        "operation_id": "operation-a",
        "agent_id": agent.AGENT_ID,
        "runtime_id": "runtime-a",
        "tool_id": "get_system_info",
        "scope": "tools:system",
        "capability": "astral.tools.system",
        "transition": "tool_system",
        "resource_dimension": 3,
        "executor_audience": "windows-executor-a",
        "channel": "a2a",
        "audit_correlation_id": "audit-a",
        "scope_profile_sha256": executor.SCOPE_PROFILE_SHA256,
        "authorized_effect_sha256": "1" * 64,
        "effect_sha256": "",
    }
    context["effect_sha256"] = executor._recompute_effect_sha256(
        context, expected_sequence=0, nonce=nonce
    )
    now = time.time_ns()
    receipt = Receipt(
        tenant_id=manifest.tenant_id,
        envelope_id=manifest.envelope_id,
        config_epoch=manifest.config_epoch,
        receipt_id="receipt-a",
        request_id="operation-a",
        warden_id=warden.warden_id,
        key_id=warden.key_id,
        policy_id=policy.policy_id,
        policy_version=policy.policy_version,
        policy_digest=policy.digest,
        machine_digest=policy.machine.digest,
        lease_id="lease-a",
        lineage_id="lineage-a",
        subject_id=agent.AGENT_ID,
        executor_audience="windows-executor-a",
        transition="tool_system",
        source_state="ready",
        target_state="ready",
        cost=(0, 0, 0, 1, 0, 0),
        resulting_sequence=1,
        evidence_digest=canonical_digest(context),
        nonce=nonce,
        issued_at_ns=now - 1_000_000_000,
        expires_at_ns=now + 30_000_000_000,
    )
    receipt = replace(
        receipt,
        signature=b64url_encode(
            warden.sign(canonical_json(receipt.unsigned_payload()))
        ),
    )
    return {
        "type": executor.PERMIT_TYPE,
        "binding_id": "binding-a",
        "owner_id": "owner-a",
        "runtime_generation": 1,
        "context": context,
        "expected_sequence": 0,
        "nonce": nonce,
        "wire_arguments_sha256": hashlib.sha256(
            executor._stable_canonical_bytes(arguments)
        ).hexdigest(),
        "receipt": receipt.to_dict(),
    }


def test_signed_manifest_public_verifier_and_replay_state_survive_restart(tmp_path):
    values, manifest, policy, warden = _environment(tmp_path)
    arguments = {}
    permit = _permit(manifest, policy, warden, arguments=arguments)
    runtime = executor.load_protected_executor(values, agent_id=agent.AGENT_ID)

    runtime.verify_and_claim(
        metadata=permit,
        final_arguments=arguments,
        tool_id="get_system_info",
        tool_scope="tools:system",
    )
    runtime.close()

    reopened = executor.load_protected_executor(values, agent_id=agent.AGENT_ID)
    with pytest.raises(executor.ProtectedExecutorError, match="receipt_replayed"):
        reopened.verify_and_claim(
            metadata=permit,
            final_arguments=arguments,
            tool_id="get_system_info",
            tool_scope="tools:system",
        )
    reopened.close()


@pytest.mark.parametrize(
    ("field", "value"),
    [("lease_id", "wrong-lease"), ("lineage_id", "wrong-lineage")],
)
def test_receipt_lease_and_lineage_must_match_host_authority(
    tmp_path, field, value
):
    values, manifest, policy, warden = _environment(tmp_path)
    permit = _permit(manifest, policy, warden, arguments={})
    permit["receipt"][field] = value
    runtime = executor.load_protected_executor(values, agent_id=agent.AGENT_ID)
    try:
        with pytest.raises(
            executor.ProtectedExecutorError,
            match="^executor_host_binding_mismatch$",
        ):
            runtime.verify_and_claim(
                metadata=permit,
                final_arguments={},
                tool_id="get_system_info",
                tool_scope="tools:system",
            )
    finally:
        runtime.close()


@pytest.mark.parametrize(
    "cost",
    [
        (0, 1, 0, 0, 0, 0),
        (1,),
        (1, 0, 0, 0, 0, 0, 0),
    ],
)
def test_receipt_cost_must_match_the_exact_scope_unit_vector(tmp_path, cost):
    values, manifest, policy, warden = _environment(tmp_path)
    permit = _permit(manifest, policy, warden, arguments={})
    permit["receipt"]["cost"] = list(cost)
    runtime = executor.load_protected_executor(values, agent_id=agent.AGENT_ID)
    try:
        with pytest.raises(
            executor.ProtectedExecutorError,
            match="^executor_cost_mismatch$",
        ):
            runtime.verify_and_claim(
                metadata=permit,
                final_arguments={},
                tool_id="get_system_info",
                tool_scope="tools:system",
            )
    finally:
        runtime.close()


@pytest.mark.parametrize(
    "name",
    ["ASTRAL_AUTHORITY_LEASE_ID", "ASTRAL_AUTHORITY_LINEAGE_ID"],
)
def test_enforce_requires_host_lease_and_lineage(tmp_path, name):
    values, _manifest, _policy, _warden = _environment(tmp_path)
    values.pop(name)

    with pytest.raises(
        executor.ProtectedExecutorConfigurationError,
        match=f"^missing_{name.lower()}$",
    ):
        executor.load_protected_executor(values, agent_id=agent.AGENT_ID)


def test_dispatch_claims_immediately_before_actuator(monkeypatch):
    events = []

    class Runtime:
        requires_permit = True

        def verify_and_claim(self, **kwargs):
            assert kwargs["metadata"] == {"permit": "exact"}
            events.append("claim")

        def close(self):
            pass

    monkeypatch.setattr(agent, "_protected_executor", Runtime())
    monkeypatch.setitem(
        agent.TOOL_REGISTRY,
        "test_protected",
        {
            "scope": "tools:system",
            "description": "test",
            "function": lambda: events.append("actuator") or {"ok": True},
        },
    )
    response = agent.dispatch(
        {
            "type": "mcp_request",
            "request_id": "request-a",
            "method": "tools/call",
            "params": {"name": "test_protected", "arguments": {}},
            "caller_capabilities": {
                executor.LETS_CALLER_CAPABILITY: {"permit": "exact"}
            },
        }
    )

    assert "error" not in response
    assert events == ["claim", "actuator"]


def test_dispatch_denies_missing_permit_without_actuation(monkeypatch):
    called = []

    class Runtime:
        requires_permit = True

        def close(self):
            pass

    monkeypatch.setattr(agent, "_protected_executor", Runtime())
    monkeypatch.setitem(
        agent.TOOL_REGISTRY,
        "test_protected",
        {
            "scope": "tools:system",
            "description": "test",
            "function": lambda: called.append(True),
        },
    )

    response = agent.dispatch(
        {
            "type": "mcp_request",
            "request_id": "request-a",
            "method": "tools/call",
            "params": {"name": "test_protected", "arguments": {}},
        }
    )

    assert response["error"] == {
        "code": -32073,
        "message": "missing_protected_permit",
        "retryable": False,
    }
    assert called == []


def test_shadow_never_claims_or_blocks_existing_tool_decision(monkeypatch):
    called = []

    class Runtime:
        requires_permit = False

        def verify_and_claim(self, **_kwargs):
            raise AssertionError("shadow must not claim or block")

        def close(self):
            pass

    monkeypatch.setattr(agent, "_protected_executor", Runtime())
    monkeypatch.setitem(
        agent.TOOL_REGISTRY,
        "test_shadow",
        {
            "scope": "tools:system",
            "description": "test",
            "function": lambda: called.append(True) or {"ok": True},
        },
    )

    response = agent.dispatch(
        {
            "type": "mcp_request",
            "request_id": "request-shadow",
            "method": "tools/call",
            "params": {"name": "test_shadow", "arguments": {}},
            "caller_capabilities": {
                executor.LETS_CALLER_CAPABILITY: {"would_deny": True}
            },
        }
    )

    assert "error" not in response
    assert called == [True]


def test_manifest_signature_tamper_fails_closed(tmp_path):
    values, _manifest, _policy, _warden = _environment(tmp_path)
    path = Path(values["LETS_SIGNED_TRUST_MANIFEST"])
    document = json.loads(path.read_text(encoding="utf-8"))
    document["tenant_id"] = "tenant-tampered"
    path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(
        executor.ProtectedExecutorConfigurationError,
        match="trust_manifest_authentication_failed",
    ):
        executor.load_protected_executor(values, agent_id=agent.AGENT_ID)


def test_frozen_authority_helper_dispatches_before_qt_import():
    windows_root = Path(__file__).resolve().parents[1]
    main_source = (windows_root / "main.py").read_text(encoding="utf-8")
    executor_source = (
        windows_root / "win_agent" / "lets_executor.py"
    ).read_text(encoding="utf-8")

    helper_flag = "--lets-executor-authority-helper"
    assert helper_flag in executor_source
    assert helper_flag in main_source
    assert main_source.index(helper_flag) < main_source.index(
        "from astral_client import __version__"
    )
