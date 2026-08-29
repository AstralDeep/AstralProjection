"""Focused branch coverage for the Windows client-local transport contract."""

import asyncio
import json
from pathlib import Path

import pytest

pytest.importorskip("PySide6")

from astral_client.app import MainWindow  # noqa: E402
from astral_client.protocol import (  # noqa: E402
    OrchestratorClient,
    parse_client_local_capability,
)


DEVICE_ID = "00000000-0000-4000-8000-000000000001"
CONNECTION_GENERATION = "00000000-0000-4000-8000-000000000002"


def _client(qapp) -> OrchestratorClient:
    client = OrchestratorClient(
        "ws://127.0.0.1:9/ws",
        "token",
        device_id=DEVICE_ID,
    )
    client.connection_generation = CONNECTION_GENERATION
    return client


def _local_final() -> dict:
    fixture = (
        Path(__file__).resolve().parents[2]
        / "contracts/fixtures/voice_075/client_local_conformance.json"
    )
    vectors = json.loads(fixture.read_text(encoding="utf-8"))["vectors"]
    return next(vector["payload"] for vector in vectors if vector["id"] == "L-P02-local-final")


@pytest.mark.parametrize(
    ("checked_at", "expires_at"),
    (
        ("not-rfc3339", "2026-08-28T12:00:10Z"),
        ("2026-08-28T12:00:00Z", None),
    ),
)
def test_client_local_capability_rejects_malformed_timestamps(
    checked_at,
    expires_at,
):
    """A typed fallback never admits a malformed temporal validity window."""

    payload = {
        "status": "unavailable",
        "checked_at": checked_at,
        "expires_at": expires_at,
    }

    assert parse_client_local_capability(payload) is None


def test_ack_settlement_rejects_a_non_exact_frame_before_state_lookup():
    """Unknown ACK fields fail closed without consulting mutable window state."""

    malformed = {
        "type": "user_message_acked",
        "schema_version": "1",
        "unexpected": True,
    }

    assert MainWindow._finish_local_submission_from_ack(object(), malformed) is None


def test_request_reconnect_closes_current_socket_and_tolerates_loop_shutdown(
    qapp,
    monkeypatch,
):
    client = _client(qapp)
    close_attempts: list[str] = []

    class FakeWs:
        def close(self):
            close_attempts.append("close")

            async def complete_close():
                close_attempts.append("completed")

            return complete_close()

    class FakeFuture:
        pass

    client._loop = object()
    client._ws = FakeWs()

    def complete(coroutine, _loop):
        asyncio.run(coroutine)
        return FakeFuture()

    monkeypatch.setattr(asyncio, "run_coroutine_threadsafe", complete)
    client.request_reconnect()
    assert close_attempts == ["close", "completed"]
    assert not client._stop

    def loop_already_closed(coroutine, _loop):
        coroutine.close()
        raise RuntimeError("event loop is closed")

    monkeypatch.setattr(asyncio, "run_coroutine_threadsafe", loop_already_closed)
    client.request_reconnect()
    assert close_attempts == ["close", "completed", "close"]
    assert not client._stop


def test_failed_local_final_send_rolls_back_only_its_ack_registration(qapp):
    client = _client(qapp)
    final = _local_final()

    client._send_voice_frame = lambda _frame: False
    assert not client.send_voice_local_frame(final)
    assert client._voice_local_pending_ack is None

    client._send_voice_frame = lambda _frame: True
    assert client.send_voice_local_frame(final)
    retained = client._voice_local_pending_ack
    assert retained is not None

    client._send_voice_frame = lambda _frame: False
    assert not client.send_voice_local_frame(final)
    assert client._voice_local_pending_ack is retained


def test_forget_local_final_requires_dict_and_exact_pending_identity(qapp):
    client = _client(qapp)
    final = _local_final()
    client._send_voice_frame = lambda _frame: True
    assert client.send_voice_local_frame(final)

    assert not client.forget_voice_local_final(final["turn_id"])
    assert not client.forget_voice_local_final(
        {**final, "submission_id": "00000000-0000-4000-8000-000000000009"}
    )
    assert client._voice_local_pending_ack is not None
    assert client.forget_voice_local_final(final)
    assert client._voice_local_pending_ack is None


def test_direct_voice_send_is_non_queueing_offline_and_on_loop_shutdown(
    qapp,
    monkeypatch,
):
    client = _client(qapp)
    statuses: list[str] = []
    client.status.connect(statuses.append)
    frame = {"type": "voice_local_ready", "schema_version": "2"}

    assert not client._send_voice_frame(frame)
    assert statuses == ["voice_submission_pending"]
    assert not client._pending

    class FakeWs:
        async def send(self, _raw):
            raise AssertionError("a closed loop cannot start socket I/O")

    client._connected = True
    client._loop = object()
    client._ws = FakeWs()

    def loop_already_closed(coroutine, _loop):
        coroutine.close()
        raise RuntimeError("event loop is closed")

    monkeypatch.setattr(asyncio, "run_coroutine_threadsafe", loop_already_closed)
    assert not client._send_voice_frame(frame)
    assert statuses == ["voice_submission_pending", "voice_submission_pending"]
    assert not client._pending


def test_direct_voice_send_serializes_current_socket_frame_and_observes_future(
    qapp,
    monkeypatch,
):
    client = _client(qapp)
    sent: list[dict] = []
    callbacks = []
    frame = {"type": "voice_local_ready", "schema_version": "2", "locale": "en-US"}

    class FakeWs:
        async def send(self, raw):
            sent.append(json.loads(raw))

    class FakeFuture:
        def add_done_callback(self, callback):
            callbacks.append(callback)

    def complete(coroutine, _loop):
        asyncio.run(coroutine)
        return FakeFuture()

    client._connected = True
    client._loop = object()
    client._ws = FakeWs()
    monkeypatch.setattr(asyncio, "run_coroutine_threadsafe", complete)

    assert client._send_voice_frame(frame)
    assert sent == [frame]
    assert callbacks == [client._consume_host_send_result]
    assert not client._pending
