"""Windows-side feature-060 BYO runtime compatibility and fencing tests."""

from __future__ import annotations

import hashlib
import json
import os
import time
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

from astral_client.protocol import (
    AgentHostRegistered,
    AgentHostRegistrationRefused,
    OrchestratorClient,
    RUNTIME_CONTRACT_VERSIONS,
    RUNTIME_LOCK_ARTIFACT,
    RUNTIME_LOCK_SHA256,
    WindowsProtocolError,
    parse_runtime_frame,
)
from win_agent.byo_host import (
    BUNDLE_FILE_NAMES,
    BYO_RUNTIME_CONTRACT_VERSION,
    ByoAgentHost,
    canonical_bundle_sha256,
    check_runtime_compatibility,
    derive_executor_audience,
    HostIdentityError,
    load_or_create_host_id,
)
from win_agent.process_supervision import OutputStream


_ROOT = Path(__file__).resolve().parents[2]
_LOCK_FIXTURE_PATH = _ROOT / "windows-client" / "deployment" / "runtime-lock-contract.json"
_LOCK_FIXTURE = json.loads(_LOCK_FIXTURE_PATH.read_text(encoding="utf-8"))

HOST_ID = "d373d586-c430-4668-90e7-3652ca86b88a"
HOST_SESSION_ID = "58bc14f3-af9a-4cf8-beb2-a58e3092117f"
DELIVERY_ID = "9081134a-5fbf-4464-b685-925734fbf260"
REVISION_ID = "d083f22c-7f71-47bd-b5e1-d71068b3fdad"
RUNTIME_INSTANCE_ID = "5036fe64-65e4-4e79-99cb-942b7ca5e58f"
AGENT_ID = "ua-example-abc123"


def _bundle() -> dict[str, str]:
    return {
        "agent_main.py": "# deterministic v3 child\n",
        "astralprims_ui.py": "def build_ui():\n    return []\n",
        "protected_executor.py": "# reviewed public LETS adapter\n",
        "mcp_tools.py": "TOOL_REGISTRY = {}\n",
    }


def _ack(*, inventory_required: bool = False) -> dict:
    return {
        "type": "agent_host_registered",
        "host_id": HOST_ID,
        "host_session_id": HOST_SESSION_ID,
        "inventory_required": inventory_required,
        "accepted_at": "2026-07-15T18:41:00Z",
    }


def _delivery(files: dict[str, str] | None = None) -> dict:
    files = files or _bundle()
    return {
        "type": "agent_bundle_deliver",
        "fence": {
            "agent_id": AGENT_ID,
            "host_id": HOST_ID,
            "host_session_id": HOST_SESSION_ID,
            "delivery_id": DELIVERY_ID,
            "revision_id": REVISION_ID,
            "runtime_instance_id": RUNTIME_INSTANCE_ID,
            "lifecycle_generation": 14,
        },
        "authority": None,
        "runtime_contract_version": BYO_RUNTIME_CONTRACT_VERSION,
        "required_runtime_lock_sha256": RUNTIME_LOCK_SHA256,
        "bundle_sha256": canonical_bundle_sha256(files),
        "files": files,
    }


def _authority(*, fence: dict | None = None) -> dict:
    fence = fence or _delivery()["fence"]
    return {
        "owner_id": "owner-123",
        "binding_id": "binding-456",
        "lease_id": "lease-789",
        "lineage_id": "lineage-012",
        "population": "byo_user",
        "executor_audience": derive_executor_audience(
            fence["host_id"], fence["host_session_id"]
        ),
        "agent_id": fence["agent_id"],
        "runtime_instance_id": fence["runtime_instance_id"],
        "lifecycle_generation": fence["lifecycle_generation"],
    }


class _RawProcess:
    pid = 4242

    def poll(self):
        return None


class _FakeSupervised:
    def __init__(self, process_id, callbacks):
        self.process_id = process_id
        self.raw_process = _RawProcess()
        self._callbacks = callbacks
        self.written: list[str] = []
        self.terminated = False

    def poll(self):
        return None if not self.terminated else -15

    def write_line(self, value: str) -> None:
        self.written.append(value)

    def terminate(self, *, reason):
        self.terminated = True
        snapshot = SimpleNamespace(exit_code=-15, cleanup_error=None)
        self._callbacks["on_exit"](self, snapshot)
        return snapshot


class _RecordingSupervisor:
    def __init__(self, events: list[str] | None = None):
        self.events = events if events is not None else []
        self.spawns: list[dict] = []
        self.children: list[_FakeSupervised] = []

    def spawn(self, **kwargs):
        self.events.append("spawn")
        self.spawns.append(kwargs)
        callbacks = {
            name: kwargs[name]
            for name in ("on_stdout_line", "on_stderr_line", "on_stream_eof", "on_exit")
        }
        child = _FakeSupervised(kwargs["process_id"], callbacks)
        self.children.append(child)
        return child


def _wait_for(predicate, timeout: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


def test_tracked_runtime_lock_fixture_is_the_only_windows_contract_source() -> None:
    assert BYO_RUNTIME_CONTRACT_VERSION == _LOCK_FIXTURE["runtime_contract_version"]
    assert RUNTIME_CONTRACT_VERSIONS == (BYO_RUNTIME_CONTRACT_VERSION,)
    assert RUNTIME_LOCK_ARTIFACT == "requirements-release.lock.txt"
    assert _LOCK_FIXTURE["lock_artifact"] == (
        "windows-client/requirements-release.lock.txt"
    )
    assert RUNTIME_LOCK_SHA256 == _LOCK_FIXTURE["lock_digest"]
    lock_path = _ROOT / _LOCK_FIXTURE["lock_artifact"]
    assert hashlib.sha256(lock_path.read_bytes()).hexdigest() == RUNTIME_LOCK_SHA256
    digest_vector = _LOCK_FIXTURE["bundle_digest_vector"]
    assert _LOCK_FIXTURE["bundle_digest_contract"] == "canonical-json-utf8-v1"
    assert canonical_bundle_sha256(digest_vector["files"]) == (
        digest_vector["bundle_sha256"]
    )

    for vector in _LOCK_FIXTURE["compatibility_vectors"]:
        refusal = check_runtime_compatibility(
            vector["advertised_runtime_contract_version"],
            vector["advertised_lock_digest"],
        )
        assert (refusal is None) is vector["compatible"]
        if not vector["compatible"]:
            assert refusal == vector["refusal_code"]


def test_executor_audience_derivation_matches_deep_canonical_vector() -> None:
    assert derive_executor_audience(
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
    ) == (
        "astraldeep.byo-executor/v1:"
        "9e7551f451da68f7e25858d30b1947d3ee6befade36e6a91ee00f4b5cbd25f06"
    )


def test_v2_is_explicitly_legacy_and_never_launched(tmp_path) -> None:
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    host.handle_frame(dict(_delivery(), runtime_contract_version=2))

    assert check_runtime_compatibility(2, RUNTIME_LOCK_SHA256) == (
        "legacy_runtime_dispatch_mediated_only"
    )
    assert supervisor.spawns == []


def test_off_launch_has_no_authority_or_binding_state(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("LETS_MODE", "off")
    monkeypatch.setenv("ASTRAL_AUTHORITY_BINDING_ID", "must-not-be-inherited")
    monkeypatch.setenv("ASTRAL_AUTHORITY_LEASE_ID", "must-not-be-inherited")
    monkeypatch.setenv("ASTRAL_AUTHORITY_LINEAGE_ID", "must-not-be-inherited")
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    host.handle_frame(_delivery())

    environment = supervisor.spawns[0]["env"]
    assert environment["LETS_MODE"] == "off"
    assert "ASTRAL_RUNTIME_AUTHORITY_JSON" not in environment
    assert "ASTRAL_AUTHORITY_OWNER_ID" not in environment
    assert "ASTRAL_AUTHORITY_BINDING_ID" not in environment
    assert "ASTRAL_AUTHORITY_LEASE_ID" not in environment
    assert "ASTRAL_AUTHORITY_LINEAGE_ID" not in environment
    assert "LETS_EXECUTOR_INSTANCE_ID" not in environment


def test_enforced_launch_requires_and_cross_checks_external_authority(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setenv("LETS_MODE", "enforce")
    manifest_ref = str(tmp_path / "host-state" / "signed-manifest.json")
    operator_ref = str(tmp_path / "host-state" / "operator-keys.json")
    replay_ref = str(tmp_path / "host-state" / "replay")
    anchor_ref = str(tmp_path / "independent-state" / "authority")
    monkeypatch.setenv("LETS_SIGNED_TRUST_MANIFEST", manifest_ref)
    monkeypatch.setenv("LETS_MANIFEST_OPERATOR_KEYS_FILE", operator_ref)
    monkeypatch.setenv("LETS_EXECUTOR_DB_ROOT", replay_ref)
    monkeypatch.setenv("LETS_EXECUTOR_AUTHORITY_ROOT", anchor_ref)
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    missing = _delivery()
    host.handle_frame(missing)
    assert supervisor.spawns == []

    protected = _delivery()
    protected["authority"] = _authority(fence=protected["fence"])
    host.handle_frame(protected)
    environment = supervisor.spawns[0]["env"]
    assert json.loads(environment["ASTRAL_RUNTIME_AUTHORITY_JSON"]) == (
        protected["authority"]
    )
    assert environment["LETS_EXECUTOR_INSTANCE_ID"] == derive_executor_audience(
        HOST_ID, HOST_SESSION_ID
    )
    assert environment["ASTRAL_RUNTIME_ID"] == RUNTIME_INSTANCE_ID
    assert environment["ASTRAL_RUNTIME_GENERATION"] == "14"
    assert environment["ASTRAL_AUTHORITY_LEASE_ID"] == "lease-789"
    assert environment["ASTRAL_AUTHORITY_LINEAGE_ID"] == "lineage-012"
    assert environment["LETS_SIGNED_TRUST_MANIFEST"] == manifest_ref
    assert environment["LETS_MANIFEST_OPERATOR_KEYS_FILE"] == operator_ref
    assert environment["LETS_EXECUTOR_DB_ROOT"] == replay_ref
    assert environment["LETS_EXECUTOR_AUTHORITY_ROOT"] == anchor_ref
    persisted = "".join(
        path.read_text(encoding="utf-8")
        for path in (
            tmp_path / AGENT_ID / "revisions" / REVISION_ID
        ).iterdir()
    )
    for host_only_value in (
        protected["authority"]["owner_id"],
        protected["authority"]["binding_id"],
        protected["authority"]["lease_id"],
        protected["authority"]["lineage_id"],
        manifest_ref,
        operator_ref,
        replay_ref,
        anchor_ref,
    ):
        assert host_only_value not in persisted


def test_shadow_launch_accepts_degraded_null_or_bound_authority(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setenv("LETS_MODE", "shadow")
    degraded_supervisor = _RecordingSupervisor()
    degraded = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path / "degraded"),
        host_id=HOST_ID,
        process_supervisor=degraded_supervisor,
    )
    degraded.handle_frame(_ack())
    degraded.handle_frame(_delivery())
    degraded_environment = degraded_supervisor.spawns[0]["env"]
    assert degraded_environment["LETS_MODE"] == "shadow"
    assert "ASTRAL_RUNTIME_AUTHORITY_JSON" not in degraded_environment

    bound_supervisor = _RecordingSupervisor()
    bound = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path / "bound"),
        host_id=HOST_ID,
        process_supervisor=bound_supervisor,
    )
    bound.handle_frame(_ack())
    delivery = _delivery()
    delivery["authority"] = _authority(fence=delivery["fence"])
    bound.handle_frame(delivery)
    assert json.loads(
        bound_supervisor.spawns[0]["env"]["ASTRAL_RUNTIME_AUTHORITY_JSON"]
    ) == delivery["authority"]


def test_authority_mismatch_refuses_without_logging_or_persisting_values(
    tmp_path, monkeypatch, caplog
) -> None:
    monkeypatch.setenv("LETS_MODE", "enforce")
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    delivery = _delivery()
    authority = _authority(fence=delivery["fence"])
    authority["binding_id"] = "sensitive-binding-value"
    authority["executor_audience"] = "wrong-audience"
    delivery["authority"] = authority

    host.handle_frame(delivery)

    assert supervisor.spawns == []
    assert "sensitive-binding-value" not in caplog.text
    revision = tmp_path / AGENT_ID / "revisions" / REVISION_ID
    assert not revision.exists()


@pytest.mark.parametrize("missing", ["lease_id", "lineage_id"])
def test_enforced_launch_refuses_incomplete_lease_authority(
    tmp_path, monkeypatch, missing
) -> None:
    monkeypatch.setenv("LETS_MODE", "enforce")
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    delivery = _delivery()
    authority = _authority(fence=delivery["fence"])
    authority.pop(missing)
    delivery["authority"] = authority

    host.handle_frame(delivery)

    assert supervisor.spawns == []
    assert not (tmp_path / AGENT_ID / "revisions" / REVISION_ID).exists()


def test_host_identity_is_uuid4_and_persists_across_processes(tmp_path) -> None:
    first = load_or_create_host_id(str(tmp_path))
    second = load_or_create_host_id(str(tmp_path))

    assert first == second
    assert uuid.UUID(first).version == 4
    assert json.loads((tmp_path / ".host-identity.json").read_text())["host_id"] == first


def test_corrupt_host_identity_fails_closed_instead_of_silently_rotating(tmp_path) -> None:
    (tmp_path / ".host-identity.json").write_text(
        '{"schema_version":1,"host_id":"not-a-uuid"}\n', encoding="utf-8"
    )
    with pytest.raises(HostIdentityError):
        load_or_create_host_id(str(tmp_path))

    with pytest.raises(ValueError):
        canonical_bundle_sha256({"agent_main.py": "incomplete"})


def test_protocol_registration_uses_persisted_identity_and_structured_metadata(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setenv("BYO_AGENTS_DIR", str(tmp_path))
    client = OrchestratorClient("ws://127.0.0.1/ws", "token", host_id=HOST_ID)

    frame = client._register_frame()

    assert frame["agent_host"] == {
        "host_id": HOST_ID,
        "supported_runtime_contract_versions": [3],
        "runtime_lock_sha256": RUNTIME_LOCK_SHA256,
        "platform": "windows",
        "client_version": "0.5.0",
    }
    assert "host_session_id" not in frame["agent_host"]

    # Session-fenced frames are never replayed from the generic reconnect queue.
    client.send_host_frame(
        {
            "type": "agent_runtime_heartbeat",
            "host_session_id": HOST_SESSION_ID,
        }
    )
    assert list(client._pending) == []


def test_protocol_binds_only_one_matching_server_session_ack() -> None:
    client = OrchestratorClient("ws://127.0.0.1/ws", "token", host_id=HOST_ID)
    client._register_frame()

    assert client._handle_runtime_frame(_ack()) is True
    assert client.host_session_id == HOST_SESSION_ID

    replacement = dict(_ack(), host_session_id=str(uuid.uuid4()))
    assert client._handle_runtime_frame(replacement) is False
    assert client.host_session_id == HOST_SESSION_ID
    assert client._handle_runtime_frame(dict(_ack(), host_id=str(uuid.uuid4()))) is False


@pytest.mark.parametrize(
    "frame",
    [
        {
            "type": "agent_host_registration_refused",
            "code": "runtime_contract_unsupported",
            "retryable": False,
            "details": {
                "required_runtime_contract_version": 3,
                "supported_runtime_contract_versions": [1],
            },
            "refused_at": "2026-07-15T18:41:00Z",
        },
        {
            "type": "agent_host_registration_refused",
            "code": "runtime_lock_mismatch",
            "retryable": False,
            "details": {
                "expected_sha256_prefix": "0123456789ab",
                "actual_sha256_prefix": "fedcba987654",
            },
            "refused_at": "2026-07-15T18:41:00Z",
        },
        {
            "type": "agent_host_registration_refused",
            "code": "invalid_host_registration",
            "retryable": False,
            "details": {"field": "client_version"},
            "refused_at": "2026-07-15T18:41:00Z",
        },
    ],
)
def test_exact_host_refusal_envelopes_are_prompt_and_non_binding(frame) -> None:
    started = time.monotonic()
    parsed = parse_runtime_frame(frame)

    assert isinstance(parsed, AgentHostRegistrationRefused)
    assert time.monotonic() - started < 2.0
    assert "host_session_id" not in frame


def test_malformed_refusal_cannot_bind_or_leak_an_invalid_value() -> None:
    bad = {
        "type": "agent_host_registration_refused",
        "code": "runtime_lock_mismatch",
        "retryable": False,
        "details": {
            "expected_sha256_prefix": "not-a-prefix",
            "actual_sha256_prefix": "fedcba987654",
            "path": "C:/secret/runtime.lock",
        },
        "refused_at": "2026-07-15T18:41:00Z",
    }
    with pytest.raises(WindowsProtocolError):
        parse_runtime_frame(bad)


def test_ack_is_required_before_inventory_or_bundle_start(tmp_path) -> None:
    frames: list[dict] = []
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )

    host.on_ui_connected()
    assert frames == []
    assert host.handle_frame(_delivery()) is True
    assert supervisor.spawns == []

    host.handle_frame(_ack(inventory_required=True))
    assert [frame["type"] for frame in frames] == ["agent_host_inventory"]
    assert frames[0]["host_session_id"] == HOST_SESSION_ID
    assert frames[0]["entries"] == []


def test_missing_host_ack_fails_within_two_seconds_and_starts_nothing(tmp_path) -> None:
    notices: list[tuple[str, str]] = []
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        notify=lambda text, level="info": notices.append((text, level)),
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
        host_ack_timeout=0.05,
    )
    started = time.monotonic()
    host.on_ui_connected()

    assert _wait_for(lambda: bool(notices), timeout=0.2)
    assert time.monotonic() - started < 2.0
    assert notices[-1][1] == "error"
    assert supervisor.spawns == []
    host.stop_all()


def test_inventory_reconciliation_precedes_retained_start_and_is_exact(tmp_path) -> None:
    files = _bundle()
    first_supervisor = _RecordingSupervisor()
    first = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=first_supervisor,
    )
    first.handle_frame(_ack())
    assert first.handle_frame(_delivery(files)) is True
    assert len(first_supervisor.spawns) == 1
    first.stop_all()

    frames: list[dict] = []
    supervisor = _RecordingSupervisor()
    restarted = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    restarted.on_ui_connected()
    restarted.handle_frame(_ack(inventory_required=True))

    inventory = frames[-1]
    assert inventory["type"] == "agent_host_inventory"
    assert inventory["entries"] == [
        {
            "agent_id": AGENT_ID,
            "revision_id": REVISION_ID,
            "bundle_sha256": canonical_bundle_sha256(files),
            "runtime_contract_version": 3,
            "required_runtime_lock_sha256": RUNTIME_LOCK_SHA256,
        }
    ]
    assert supervisor.spawns == []

    restarted.handle_frame(
        {
            "type": "agent_host_inventory_reconciled",
            "host_id": HOST_ID,
            "host_session_id": HOST_SESSION_ID,
            "inventory_id": inventory["inventory_id"],
            "actions": [
                {
                    "agent_id": AGENT_ID,
                    "revision_id": REVISION_ID,
                    "action": "start",
                    "reason_code": None,
                    "selected_delivery": {
                        "delivery_id": str(uuid.uuid4()),
                        "runtime_instance_id": str(uuid.uuid4()),
                        "lifecycle_generation": 15,
                        "runtime_contract_version": 3,
                        "required_runtime_lock_sha256": RUNTIME_LOCK_SHA256,
                        "bundle_sha256": canonical_bundle_sha256(files),
                        "authority": None,
                    },
                }
            ],
            "reconciled_at": "2026-07-15T18:41:01Z",
        }
    )
    assert len(supervisor.spawns) == 1


def test_invalid_inventory_is_all_or_nothing_and_valid_delete_removes_revision(
    tmp_path,
) -> None:
    files = _bundle()
    first = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=_RecordingSupervisor(),
    )
    first.handle_frame(_ack())
    first.handle_frame(_delivery(files))
    first.stop_all()

    frames: list[dict] = []
    supervisor = _RecordingSupervisor()
    restarted = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    restarted.handle_frame(_ack(inventory_required=True))
    inventory = frames[-1]
    invalid = {
        "type": "agent_host_inventory_reconciled",
        "host_id": HOST_ID,
        "host_session_id": HOST_SESSION_ID,
        "inventory_id": inventory["inventory_id"],
        "actions": [],
        "reconciled_at": "2026-07-15T18:41:01Z",
    }
    assert restarted.handle_frame(invalid) is True
    revision_dir = tmp_path / AGENT_ID / "revisions" / REVISION_ID
    assert revision_dir.exists()
    assert supervisor.spawns == []

    valid = dict(
        invalid,
        actions=[
            {
                "agent_id": AGENT_ID,
                "revision_id": REVISION_ID,
                "action": "delete",
                "reason_code": "agent_deleted",
                "selected_delivery": None,
            }
        ],
    )
    restarted.handle_frame(valid)
    assert not revision_dir.exists()
    # The last revision's deletion takes the empty ``revisions/`` shell and the
    # agent root with it — a leftover root is reported as an installed agent by
    # ``inventory()`` (rig finding 2026-09-03).
    assert not (tmp_path / AGENT_ID).exists()
    assert restarted.inventory() == []
    assert supervisor.spawns == []


def test_install_is_staged_immutable_and_process_id_is_allocated_at_spawn(
    tmp_path, monkeypatch
) -> None:
    events: list[str] = []
    supervisor = _RecordingSupervisor(events)
    monkeypatch.setenv("PRIVATE_PROVIDER_TOKEN", "must-not-reach-authored-code")

    def process_id_factory():
        events.append("process_id")
        return uuid.UUID("b51280a7-e558-46f4-9dd9-866ab09758c2")

    frames: list[dict] = []
    host = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
        process_id_factory=process_id_factory,
        heartbeat_interval=0.02,
    )
    host.handle_frame(_ack())
    delivery = _delivery()
    host.handle_frame(delivery)

    assert events == ["process_id", "spawn"]
    assert "PRIVATE_PROVIDER_TOKEN" not in supervisor.spawns[0]["env"]
    assert supervisor.spawns[0]["env"]["ASTRAL_RUNTIME_FENCE_JSON"]
    revision_dir = tmp_path / AGENT_ID / "revisions" / REVISION_ID
    assert revision_dir.is_dir()
    assert set(path.name for path in revision_dir.iterdir()) == (
        set(BUNDLE_FILE_NAMES) | {".astraldeep-runtime.json"}
    )
    assert not any((tmp_path / ".staging").iterdir())
    assert [frame["type"] for frame in frames] == ["agent_runtime_state"]
    starting = frames[0]
    assert starting["state"] == "starting"
    assert starting["fence"]["process_id"] == "b51280a7-e558-46f4-9dd9-866ab09758c2"

    callback = supervisor.spawns[0]["on_stdout_line"]
    registration = {
        "type": "agent_runtime_register",
        "fence": starting["fence"],
        "runtime_contract_version": 3,
        "bundle_sha256": delivery["bundle_sha256"],
        "agent_card": {
            "name": "Example Agent",
            "description": "A bounded description",
            "agent_id": AGENT_ID,
            "version": "0.1.0",
            "skills": [],
            "metadata": {},
        },
    }
    callback(json.dumps(registration).encode("utf-8"))

    assert _wait_for(
        lambda: {frame["type"] for frame in frames}
        >= {"agent_runtime_register", "agent_runtime_heartbeat"}
    )
    frame_types = [frame["type"] for frame in frames]
    assert frame_types[:4] == [
        "agent_runtime_state",
        "agent_runtime_register",
        "agent_runtime_heartbeat",
        "agent_runtime_state",
    ]
    assert frames[3]["state"] == "ready"
    assert frames[2]["heartbeat_sequence"] == 1
    assert all(
        frame.get("fence") == starting["fence"]
        for frame in frames
        if frame["type"].startswith("agent_runtime_")
    )

    host.stop_all()
    exits = [frame for frame in frames if frame["type"] == "agent_runtime_exit"]
    assert exits == [
        {
            "type": "agent_runtime_exit",
            "fence": starting["fence"],
            "exit_kind": "explicit_stop",
            "exit_code": None,
        }
    ]


def test_mismatched_first_registration_fails_and_duplicate_delivery_spawns_once(
    tmp_path,
) -> None:
    frames: list[dict] = []
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
        heartbeat_interval=0.02,
    )
    host.handle_frame(_ack())
    delivery = _delivery()
    host.handle_frame(delivery)
    host.handle_frame(delivery)
    assert len(supervisor.spawns) == 1

    starting = frames[0]
    wrong = {
        "type": "agent_runtime_register",
        "fence": dict(starting["fence"], runtime_instance_id=str(uuid.uuid4())),
        "runtime_contract_version": 3,
        "bundle_sha256": delivery["bundle_sha256"],
        "agent_card": {
            "name": "Example",
            "description": "Example",
            "agent_id": AGENT_ID,
            "version": "0.1.0",
            "skills": [],
            "metadata": {},
        },
    }
    supervisor.spawns[0]["on_stdout_line"](json.dumps(wrong).encode())
    assert _wait_for(lambda: supervisor.children[0].terminated)
    assert any(
        frame.get("type") == "agent_runtime_state"
        and frame.get("state") == "failed"
        and frame.get("reason_code") == "child_registration_timeout"
        for frame in frames
    )
    assert not any(frame.get("state") == "ready" for frame in frames)


def test_registered_runtime_heartbeats_once_per_second_with_monotonic_sequence(
    tmp_path,
) -> None:
    observed: list[tuple[float, dict]] = []
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda frame: observed.append((time.monotonic(), frame)),
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    delivery = _delivery()
    host.handle_frame(delivery)
    fence = observed[0][1]["fence"]
    supervisor.spawns[0]["on_stdout_line"](
        json.dumps(
            {
                "type": "agent_runtime_register",
                "fence": fence,
                "runtime_contract_version": 3,
                "bundle_sha256": delivery["bundle_sha256"],
                "agent_card": {
                    "name": "Example",
                    "description": "Example",
                    "agent_id": AGENT_ID,
                    "version": "0.1.0",
                    "skills": [],
                    "metadata": {},
                },
            }
        ).encode()
    )
    try:
        assert _wait_for(
            lambda: len(
                [frame for _at, frame in observed if frame["type"] == "agent_runtime_heartbeat"]
            )
            >= 3,
            timeout=2.3,
        )
        heartbeats = [
            (at, frame)
            for at, frame in observed
            if frame["type"] == "agent_runtime_heartbeat"
        ][:3]
        assert [frame["heartbeat_sequence"] for _at, frame in heartbeats] == [1, 2, 3]
        gaps = [heartbeats[index][0] - heartbeats[index - 1][0] for index in (1, 2)]
        assert all(0.85 <= gap <= 1.15 for gap in gaps)
    finally:
        host.stop_all()


def test_fenced_tunnel_and_all_three_exit_kinds_are_exact(tmp_path) -> None:
    frames: list[dict] = []
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
        heartbeat_interval=0.02,
    )
    host.handle_frame(_ack())
    delivery = _delivery()
    host.handle_frame(delivery)
    fence = frames[0]["fence"]
    registration = {
        "type": "agent_runtime_register",
        "fence": fence,
        "runtime_contract_version": 3,
        "bundle_sha256": delivery["bundle_sha256"],
        "agent_card": {
            "name": "Example",
            "description": "Example",
            "agent_id": AGENT_ID,
            "version": "0.1.0",
            "skills": [],
            "metadata": {},
        },
    }
    supervisor.spawns[0]["on_stdout_line"](json.dumps(registration).encode())
    request = {
        "type": "mcp_request",
        "fence": fence,
        "request_id": str(uuid.uuid4()),
        "request_generation": str(uuid.uuid4()),
    }
    host.handle_frame({"type": "agent_tunnel", "fence": fence, "frame": request})
    assert json.loads(supervisor.children[0].written[-1]) == request
    before = list(supervisor.children[0].written)
    host.handle_frame(
        {
            "type": "agent_tunnel",
            "fence": fence,
            "frame": dict(request, request_generation="stale"),
        }
    )
    assert supervisor.children[0].written == before

    supervisor.spawns[0]["on_exit"](
        supervisor.children[0], SimpleNamespace(exit_code=23)
    )
    assert [frame for frame in frames if frame["type"] == "agent_runtime_exit"][-1][
        "exit_kind"
    ] == "process_exit"
    assert [frame for frame in frames if frame["type"] == "agent_runtime_exit"][-1][
        "exit_code"
    ] == 23

    # A fresh runtime whose stdout protocol closes while the process remains
    # alive is killed and reported as protocol_eof, never as raw diagnostics.
    second_delivery = _delivery()
    second_delivery["fence"] = dict(
        second_delivery["fence"],
        delivery_id=str(uuid.uuid4()),
        runtime_instance_id=str(uuid.uuid4()),
        lifecycle_generation=15,
    )
    host.handle_frame(second_delivery)
    supervisor.spawns[-1]["on_stream_eof"](OutputStream.STDOUT)
    assert _wait_for(lambda: supervisor.children[-1].terminated)
    assert [frame for frame in frames if frame["type"] == "agent_runtime_exit"][-1][
        "exit_kind"
    ] == "protocol_eof"


def test_disconnect_stops_current_tree_without_sending_a_stale_exit(tmp_path) -> None:
    frames: list[dict] = []
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    host.handle_frame(_delivery())
    before = len([frame for frame in frames if frame["type"] == "agent_runtime_exit"])

    host.on_transport_disconnected()

    assert supervisor.children[0].terminated is True
    after = len([frame for frame in frames if frame["type"] == "agent_runtime_exit"])
    assert after == before


def test_digest_mismatch_never_installs_or_spawns(tmp_path) -> None:
    supervisor = _RecordingSupervisor()
    host = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=supervisor,
    )
    host.handle_frame(_ack())
    bad = dict(_delivery(), bundle_sha256="0" * 64)

    host.handle_frame(bad)

    assert supervisor.spawns == []
    assert not (tmp_path / AGENT_ID / "revisions" / REVISION_ID).exists()


def test_real_worker_receives_the_full_fence_and_registers_before_ready(tmp_path) -> None:
    files = _bundle()
    files["agent_main.py"] = (
        "import json, os, sys\n"
        "def main():\n"
        "    fence = json.loads(os.environ['ASTRAL_RUNTIME_FENCE_JSON'])\n"
        "    frame = {\n"
        "        'type': 'agent_runtime_register',\n"
        "        'fence': fence,\n"
        "        'runtime_contract_version': int(os.environ['ASTRAL_RUNTIME_CONTRACT_VERSION']),\n"
        "        'bundle_sha256': os.environ['ASTRAL_RUNTIME_BUNDLE_SHA256'],\n"
        "        'agent_card': {\n"
        f"            'name': 'Example', 'description': 'Example', 'agent_id': {AGENT_ID!r},\n"
        "            'version': '0.1.0', 'skills': [], 'metadata': {},\n"
        "        },\n"
        "    }\n"
        "    print(json.dumps(frame), flush=True)\n"
        "    for _line in sys.stdin:\n"
        "        pass\n"
        "    return 0\n"
    )
    frames: list[dict] = []
    host = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        register_timeout=2,
        heartbeat_interval=0.05,
    )
    host.handle_frame(_ack())
    delivery = _delivery(files)

    try:
        assert host.handle_frame(delivery) is True
        assert _wait_for(
            lambda: any(
                frame.get("type") == "agent_runtime_state"
                and frame.get("state") == "ready"
                for frame in frames
            ),
            timeout=5,
        )
        types = [frame["type"] for frame in frames]
        assert types[:4] == [
            "agent_runtime_state",
            "agent_runtime_register",
            "agent_runtime_heartbeat",
            "agent_runtime_state",
        ]
        starting_fence = frames[0]["fence"]
        registration = frames[1]
        assert registration["fence"] == starting_fence
        assert registration["bundle_sha256"] == canonical_bundle_sha256(files)
        child = next(iter(host._runtime_children.values()))
        assert starting_fence["process_id"] != str(child.proc.pid)
    finally:
        host.stop_all()
    assert len(
        [frame for frame in frames if frame["type"] == "agent_runtime_exit"]
    ) == 1


def test_agent_host_ack_model_is_frozen_and_exact() -> None:
    parsed = parse_runtime_frame(_ack())
    assert isinstance(parsed, AgentHostRegistered)
    with pytest.raises(Exception):
        parsed.host_session_id = str(uuid.uuid4())  # type: ignore[misc]


def test_prelaunch_fence_accepts_the_servers_explicit_null_process_id() -> None:
    """Feature 077 live finding: Deep's canonical ``RuntimeFence.to_dict()``
    serializes ``process_id: None`` before launch (a dataclass ``asdict``), and
    the host refused every real delivery as 'pre-launch fence fields are
    invalid' — the express lane's first delivered agent was discarded on the
    PC. An explicit null IS the pre-launch shape; a bound process on this frame
    is still refused."""
    from win_agent.byo_host import ByoAgentHost

    base = {
        "agent_id": AGENT_ID,
        "host_id": HOST_ID,
        "host_session_id": HOST_SESSION_ID,
        "delivery_id": DELIVERY_ID,
        "revision_id": REVISION_ID,
        "runtime_instance_id": RUNTIME_INSTANCE_ID,
        "lifecycle_generation": 14,
    }
    assert ByoAgentHost._prelaunch_fence(dict(base, process_id=None)) == base
    assert ByoAgentHost._prelaunch_fence(dict(base)) == base
    with pytest.raises(ValueError, match="pre-launch fence fields are invalid"):
        ByoAgentHost._prelaunch_fence(dict(base, process_id=str(uuid.uuid4())))
    with pytest.raises(ValueError):
        ByoAgentHost._prelaunch_fence(dict(base, extra=1))


def test_a_revision_that_ran_once_survives_the_next_inventory_scan(tmp_path) -> None:
    """Feature 077 live finding: Python wrote ``__pycache__`` into the revision
    directory when the worker imported the agent, the exact-listing check then
    called the revision corrupt on the next reconnect and DELETED it — every
    personal agent that had ever run vanished at the next client restart."""
    files = _bundle()
    first_supervisor = _RecordingSupervisor()
    first = ByoAgentHost(
        send_frame=lambda _frame: None,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=first_supervisor,
    )
    first.handle_frame(_ack())
    assert first.handle_frame(_delivery(files)) is True
    # the worker is launched with byte-code writing off …
    launch_env = first_supervisor.spawns[0].get("environment") or first_supervisor.spawns[0].get("env") or {}
    assert launch_env.get("PYTHONDONTWRITEBYTECODE") == "1"
    first.stop_all()
    # … but an older install (or a manual run) may have left the cache behind
    revision_dir = os.path.join(str(tmp_path), AGENT_ID, "revisions", REVISION_ID)
    os.makedirs(os.path.join(revision_dir, "__pycache__"))
    with open(os.path.join(revision_dir, "__pycache__", "agent_main.cpython-311.pyc"), "wb") as fh:
        fh.write(b"\x00")

    frames: list[dict] = []
    restarted = ByoAgentHost(
        send_frame=frames.append,
        base_dir=str(tmp_path),
        host_id=HOST_ID,
        process_supervisor=_RecordingSupervisor(),
    )
    restarted.on_ui_connected()
    restarted.handle_frame(_ack(inventory_required=True))
    inventory = frames[-1]
    assert inventory["type"] == "agent_host_inventory"
    assert [e["revision_id"] for e in inventory["entries"]] == [REVISION_ID]
    assert os.path.isfile(os.path.join(revision_dir, "agent_main.py"))   # not deleted
    # a genuinely foreign file is still corruption
    with open(os.path.join(revision_dir, "extra.py"), "w") as fh:
        fh.write("x")
    assert restarted._installed_revision(AGENT_ID, REVISION_ID) is None


def test_send_host_frame_accepts_the_childs_tool_result() -> None:
    """Feature 077 live finding: the host's transport guard accepted only
    ``agent_*`` frames, so the child's ``mcp_response`` — the one frame that
    carries a tool result — was refused on the way out and every personal-agent
    call timed out on the server."""
    from astral_client.protocol import OrchestratorClient, WindowsProtocolError

    client = OrchestratorClient("ws://127.0.0.1/ws", "token", host_id=HOST_ID)
    client.send_host_frame({"type": "mcp_response", "request_id": str(uuid.uuid4()),
                            "request_generation": str(uuid.uuid4()), "fence": {}, "result": {}})
    client.send_host_frame({"type": "agent_runtime_heartbeat", "host_session_id": HOST_SESSION_ID})
    assert list(client._pending) == []            # never queued for replay either way
    with pytest.raises(WindowsProtocolError):
        client.send_host_frame({"type": "chat_message", "message": "not a host frame"})
    with pytest.raises(WindowsProtocolError):
        client.send_host_frame({"type": "mcp_request"})
