"""Focused failure-path coverage for the Windows client-local speech controller."""

from __future__ import annotations

from datetime import timedelta
from typing import Any, NoReturn

import pytest

pytest.importorskip("PySide6")

from astral_client.voice import VoiceHttpError  # noqa: E402
from test_local_speech_lifecycle_075 import (  # noqa: E402
    CHAT,
    CONNECTION,
    LOCAL_FINAL_RETRY_MS,
    NOW,
    _activate,
    _announcement_frame,
    _bound_frame,
    _frames,
    _harness,
    _iso,
    _ready_frame,
    _start_session,
    _uuid,
)


def _raise(error: BaseException) -> NoReturn:
    raise error


def _session_state(harness: Any, **changes: Any) -> dict[str, Any]:
    frame = {
        "type": "voice_session_state",
        "schema_version": "1",
        "session_id": harness.controller.session_id,
        "connection_generation": CONNECTION,
        "generation": harness.controller.generation,
        "media_grant_revision": harness.controller.media_grant_revision,
        "visible_chat_id": CHAT,
        "chat_context_revision": 1,
        "applied_chat_context_revision": 1,
        "chat_context_synced": True,
        "state": "listening",
        "speech_muted": False,
        "microphone_enabled": True,
        "foreground_active": True,
        "reason": "ready",
        "occurred_at": _iso(harness.clock.now),
    }
    frame.update(changes)
    return frame


def test_binding_expiry_bounds_a_reconnect_callback_failure() -> None:
    harness = _harness()
    harness.transport.request_reconnect = lambda: _raise(RuntimeError("closed"))
    harness.clock.advance(seconds=601)

    harness.controller._expire_control_binding(
        harness.controller._control_binding_epoch,
        harness.controller.control_binding_id,
        CONNECTION,
        harness.controller.control_binding_expires_at,
    )

    assert harness.controller.control_binding is None


def test_local_session_state_stops_owners_and_reissues_readiness() -> None:
    harness = _harness()
    _start_session(harness)
    ready_count = len(_frames(harness, "voice_local_ready"))

    assert harness.controller.accept_frame(_session_state(harness, chat_context_synced=False))

    assert harness.speech.stop_all_calls == 1
    assert len(_frames(harness, "voice_local_ready")) == ready_count + 1


def test_pending_chat_activation_is_one_shot_and_cancellable() -> None:
    harness = _harness()
    harness.controller.chat_provider = lambda: None
    harness.controller.handle_action("voice_session_start")
    pending = harness.controller._pending_chat_activation
    assert pending is not None

    action, activation_id = pending
    assert not harness.controller.continue_activation(action, _uuid(900), CHAT)
    harness.controller.cancel_pending_activation()

    assert harness.controller._pending_chat_activation is None
    assert harness.controller.state == "off"
    harness.controller._closed = True
    harness.controller._activate(action, activation_id, CHAT)
    assert harness.controller._activation_id is None


def test_deferred_activation_is_fenced_after_cancellation() -> None:
    harness = _harness()
    harness.runner.defer = True
    harness.controller.handle_action("voice_session_start")
    harness.controller.cancel_pending_activation()

    harness.runner.run_all()

    assert not any(call[0] == "capability_v2" for call in harness.http.calls)


def test_activation_is_rechecked_after_each_backend_boundary() -> None:
    selection_harness = _harness()
    selection_harness.runner.defer = True
    selection = selection_harness.http.capability_v2()
    selection_harness.http.calls.clear()

    def invalidate_with_selection() -> dict[str, Any]:
        selection_harness.controller._activation_id = None
        return selection

    selection_harness.http.capability_v2 = invalidate_with_selection
    selection_harness.controller.handle_action("voice_session_start")
    selection_harness.runner.run_all()
    assert not any(call[0] == "create_local" for call in selection_harness.http.calls)

    fallback_harness = _harness()
    fallback_harness.runner.defer = True
    fallback_harness.http.capability_v2 = lambda: _raise(VoiceHttpError("backend_mismatch"))

    def invalidate_with_legacy_capability() -> dict[str, Any]:
        fallback_harness.controller._activation_id = None
        return {"status": "ready", "reason": "ready"}

    fallback_harness.http.capability = invalidate_with_legacy_capability
    fallback_harness.controller.handle_action("voice_session_start")
    fallback_harness.runner.run_all()
    assert fallback_harness.controller.session_id is None

    ready_harness = _harness()
    ready_harness.runner.defer = True
    ready_harness.http.capability_v2 = lambda: _raise(VoiceHttpError("backend_mismatch"))

    class InvalidatingReady(dict[str, Any]):
        def get(self, key: str, default: Any = None) -> Any:
            value = super().get(key, default)
            if key == "reason":
                ready_harness.controller._activation_id = None
            return value

    ready_harness.http.capability = lambda: InvalidatingReady(status="ready", reason="ready")
    ready_harness.controller.handle_action("voice_session_start")
    ready_harness.runner.run_all()
    assert ready_harness.controller.session_id is None

    error_harness = _harness()
    error_harness.runner.defer = True

    def invalidate_with_error() -> NoReturn:
        error_harness.controller._activation_epoch += 1
        raise VoiceHttpError("network_interrupted")

    error_harness.http.capability_v2 = invalidate_with_error
    error_harness.controller.handle_action("voice_session_start")
    error_harness.runner.run_all()
    assert error_harness.controller._activation_id is not None


def test_local_activation_and_ready_recheck_ownership() -> None:
    closed = _harness()
    activation_id = _uuid(901)
    closed.controller._activation_id = activation_id
    closed.controller._closed = True
    closed.controller._activate_local(
        "voice_session_start",
        activation_id,
        CHAT,
        closed.controller._scope(),
        closed.http.capability_v2(),
    )
    assert closed.controller.session_id is None

    invalidated = _harness()
    invalidated.controller._activation_id = activation_id
    original_capability = invalidated.controller._local_capability

    def lose_activation() -> dict[str, Any]:
        capability = original_capability()
        invalidated.controller._activation_id = None
        return capability

    invalidated.controller._local_capability = lose_activation
    invalidated.controller._activate_local(
        "voice_session_start",
        activation_id,
        CHAT,
        invalidated.controller._scope(),
        invalidated.http.capability_v2(),
    )
    assert invalidated.controller.session_id is None

    ready = _harness()
    _activate(ready)
    ready.controller.speech_muted = True
    assert not ready.controller._send_local_ready()
    assert not ready.controller._local_ready_pending
    ready.controller.speech_muted = False
    ready.controller._local_ready_pending = True
    assert ready.controller._send_local_ready()

    idle = _harness()
    idle.controller._reconcile_local_speech()
    assert idle.controller.session_id is None

    ready.controller.speech_muted = True
    ready.controller._reconcile_local_speech()
    assert not ready.controller._local_ready_authorized


def test_recognition_scheduler_and_adapter_failures_fail_closed() -> None:
    scheduling = _harness()
    _activate(scheduling)
    scheduling.controller._local_schedule = lambda *_args: _raise(ValueError("timer closed"))

    assert scheduling.controller.accept_frame(_ready_frame(scheduling))
    assert scheduling.controller.state == "unavailable"
    assert not scheduling.speech.cycles

    refused = _harness()
    _activate(refused)
    refused.speech.start_ok = False
    assert refused.controller.accept_frame(_ready_frame(refused))
    assert refused.controller.state == "unavailable"

    stopped = _harness()
    _start_session(stopped)
    stopped.speech.stop_all = lambda: _raise(RuntimeError("adapter gone"))
    stopped.speech.cycles[0]["error"]("engine failed")
    assert stopped.controller._local_turn is None
    assert stopped.controller.state == "unavailable"

    adapter = _harness()
    _start_session(adapter)
    adapter.speech.stop_recognition = lambda: _raise(ValueError("already stopped"))
    adapter.controller._stop_local_recognition_adapter()
    assert adapter.controller._local_speech_stopped


@pytest.mark.parametrize("bound", [False, True])
def test_malformed_local_final_is_failed_and_plaintext_is_scrubbed(bound: bool) -> None:
    harness = _harness()
    started = _start_session(harness)
    if bound:
        assert harness.controller.accept_frame(_bound_frame(harness, started))

    harness.speech.cycles[0]["final"]("unsafe\u202econtrol")

    assert harness.controller._local_turn is None
    assert harness.controller.state == "unavailable"
    assert "unsafe" not in repr(harness.controller._local_turn)
    if bound:
        assert _frames(harness, "voice_local_recognition_failed")
    else:
        assert harness.controller._local_pending_failures


def test_expired_bound_final_is_not_delivered() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started, expiry_seconds=1))
    harness.clock.advance(seconds=2)

    harness.speech.cycles[0]["final"]("too late")

    assert not _frames(harness, "voice_local_final")
    assert "too late" not in repr(harness.controller._local_turn)


def test_final_retry_and_transport_forget_failures_are_bounded() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    harness.transport.raise_types.add("voice_local_final")

    harness.speech.cycles[0]["final"]("bounded retry secret")
    pending = harness.controller._local_pending_final
    assert pending is not None
    harness.scheduler.run_first(LOCAL_FINAL_RETRY_MS)

    harness.transport.forget_voice_local_final = lambda _pending: _raise(
        RuntimeError("already forgotten")
    )
    harness.controller._clear_local_pending_final()

    assert harness.controller._local_pending_final is None
    assert "bounded retry secret" not in repr(pending)


def test_pending_final_schedule_rejects_missing_expired_and_stale_owners() -> None:
    missing = _harness()
    missing_pending = {"frame": {"text": "secret", "text_digest_sha256": "digest"}}
    missing.controller._local_pending_final = missing_pending
    missing.controller._schedule_local_final_retry(missing_pending)
    assert missing.controller._local_pending_final is None
    assert missing.controller.session_id is None

    expired = _harness()
    expired_pending = {
        "expires_at": NOW - timedelta(seconds=1),
        "frame": {"text": "secret", "text_digest_sha256": "digest"},
    }
    expired.controller._local_pending_final = expired_pending
    expired.controller._schedule_local_final_retry(expired_pending)
    assert expired.controller._local_pending_final is None

    stale = _harness()
    stale.controller._schedule_local_final_retry({})
    stale.controller._expire_local_pending_final({})
    assert stale.controller.session_id is None


def test_pending_final_expiry_bounds_server_end_failure() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    harness.speech.cycles[0]["final"]("unacknowledged")
    pending = harness.controller._local_pending_final
    assert pending is not None
    harness.http.fail_methods.add("end")

    harness.controller._expire_local_pending_final(pending)

    assert harness.controller.session_id is None
    assert harness.controller.state == "unavailable"


def test_failure_and_resume_helpers_reject_stale_work() -> None:
    harness = _harness()
    started = _start_session(harness)
    bound = _bound_frame(harness, started)
    assert harness.controller.accept_frame(bound)
    turn = harness.controller._local_turn
    assert turn is not None
    turn["failure_sent"] = True
    assert not harness.controller._send_local_recognition_failure(turn, "bad reason")
    harness.controller._on_local_error(-1, "bad reason")

    harness.controller._local_resume_requested_epoch = harness.controller._local_recognition_epoch
    harness.controller._maybe_resume_local_recognition()
    assert harness.controller._local_resume_requested_epoch is not None


def test_playout_expiry_stale_callbacks_and_stop_failure_are_bounded() -> None:
    harness = _harness()
    _start_session(harness)
    assert harness.controller.accept_frame(_announcement_frame(harness))
    active = harness.controller._local_active_playout
    assert active is not None

    harness.controller._expire_local_announcement(dict(active))
    harness.controller._expire_local_announcement(active)
    assert harness.controller._local_active_playout is active

    harness.clock.advance(seconds=11)
    harness.speech.stop_all = lambda: _raise(RuntimeError("already stopped"))
    harness.controller._expire_local_announcement(active)

    assert harness.controller._local_active_playout is None
    assert active["payload"]["text"] == ""


def test_playout_phase_validation_and_authority_rechecks() -> None:
    invalid = _harness()
    _start_session(invalid)
    assert invalid.controller.accept_frame(_announcement_frame(invalid))
    invalid.speech.playouts[0]["phase"]("unknown")
    assert _frames(invalid, "voice_local_playout_event")[-1]["phase"] == "failed"

    duplicate = _harness()
    _start_session(duplicate)
    assert duplicate.controller.accept_frame(_announcement_frame(duplicate))
    duplicate.speech.playouts[0]["phase"]("started")
    duplicate.speech.playouts[0]["phase"]("started")
    duplicate.speech.playouts[0]["phase"]("interrupted")
    phases = [frame["phase"] for frame in _frames(duplicate, "voice_local_playout_event")]
    assert phases == ["started", "interrupted"]
    assert _frames(duplicate, "voice_local_playout_event")[-1]["reason"] == (
        "local_audio_interrupted"
    )

    revoked = _harness()
    _start_session(revoked)
    assert revoked.controller.accept_frame(_announcement_frame(revoked))
    revoked.controller.speech_muted = True
    revoked.speech.stop_all = lambda: _raise(ValueError("already stopped"))
    revoked.speech.playouts[0]["phase"]("started")
    assert _frames(revoked, "voice_local_playout_event")[-1]["phase"] == "failed"

    expired = _harness()
    _start_session(expired)
    assert expired.controller.accept_frame(_announcement_frame(expired))
    expired.clock.advance(seconds=11)
    expired.speech.playouts[0]["phase"]("started")
    assert expired.controller._local_active_playout is None


def test_announcement_start_rechecks_queue_and_synthesis_result() -> None:
    expired = _harness()
    _start_session(expired)
    first = _announcement_frame(expired, sequence=1)
    second = _announcement_frame(expired, sequence=2)
    expired.controller._local_announcement_queue.append(second)
    expired.clock.advance(seconds=11)

    assert not expired.controller._start_local_announcement(first)
    assert not expired.controller._local_announcement_queue
    assert "Announcement" not in repr(expired.controller._local_active_playout)

    refused = _harness()
    _start_session(refused)
    refused.speech.speak_ok = False
    assert not refused.controller.accept_frame(_announcement_frame(refused))
    assert refused.controller._local_active_playout is None


def test_stale_playout_event_and_prestart_cancel_are_inert() -> None:
    harness = _harness()
    _start_session(harness)
    assert harness.controller.accept_frame(_announcement_frame(harness))
    active = harness.controller._local_active_playout
    assert active is not None
    harness.controller._local_playout_epoch += 1
    assert not harness.controller._send_local_playout_event(active, "started")

    harness.controller._local_playout_epoch = active["epoch"]
    harness.controller._cancel_local_playout("stopped_by_user")
    assert harness.controller._local_active_playout is None
    assert active["payload"]["text"] == ""


def test_stop_local_owners_bounds_every_adapter_and_report_failure() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    bound_turn = dict(harness.controller._local_turn or {})
    assert harness.controller.accept_frame(_announcement_frame(harness, sequence=1))
    assert harness.controller.accept_frame(_announcement_frame(harness, sequence=2))
    active = harness.controller._local_active_playout
    queued = harness.controller._local_announcement_queue[0]
    assert active is not None
    harness.controller._local_turn = bound_turn
    harness.controller._local_speech_stopped = False
    harness.speech.stop_all = lambda: _raise(RuntimeError("adapter gone"))
    harness.controller._send_local_playout_event = lambda *_args: _raise(OSError("transport gone"))
    harness.controller._send_local_recognition_failure = lambda *_args: _raise(
        ValueError("transport gone")
    )

    harness.controller._stop_local_owners("stopped_by_user")

    assert active["payload"]["text"] == ""
    assert queued["text"] == ""
    assert harness.controller._local_active_playout is None
    assert not harness.controller._local_announcement_queue
    assert harness.controller._local_turn is None


@pytest.mark.parametrize(
    ("response", "change", "expected_fragment"),
    [
        ({}, {"microphone_enabled": False}, "session update response"),
        (
            {"session_id": None, "speech_revision": 0},
            {"speech_muted": True},
            "session update revision",
        ),
    ],
)
def test_local_session_update_rejects_malformed_responses(
    response: dict[str, Any], change: dict[str, Any], expected_fragment: str
) -> None:
    harness = _harness()
    _start_session(harness)
    messages: list[str] = []
    harness.controller.status_changed.connect(lambda _state, message: messages.append(message))
    if response.get("session_id") is None and response:
        response["session_id"] = harness.controller.session_id
    harness.http.update = lambda *_args: response

    harness.controller._update_session(**change)

    assert harness.controller.state == "error"
    assert expected_fragment in messages[-1]


def test_local_chat_update_applies_exact_server_revision() -> None:
    harness = _harness()
    _start_session(harness)
    next_chat = _uuid(950)
    harness.http.update = lambda *_args: {
        "session_id": harness.controller.session_id,
        "speech_revision": 2,
        "visible_chat_id": next_chat,
        "chat_context_revision": 2,
    }

    harness.controller._update_session(visible_chat_id=next_chat)

    assert harness.controller.visible_chat_id == next_chat
    assert harness.controller.chat_context_revision == 2
    assert harness.controller.media_grant_revision == 2


def test_stop_response_advances_revision_and_blocks_duplicate_stop() -> None:
    harness = _harness()
    _start_session(harness)
    stop_calls: list[tuple[Any, ...]] = []

    def stop_speech(*args: Any) -> dict[str, int]:
        stop_calls.append(args)
        return {"speech_revision": 2}

    harness.http.stop_speech = stop_speech

    harness.controller._stop_speech()
    assert len(stop_calls) == 1
    harness.controller._stop_speech()

    assert harness.controller.media_grant_revision == 2
    assert harness.controller._local_stop_reset_pending
    assert len(stop_calls) == 1


def test_permission_loss_tears_down_local_session_once() -> None:
    harness = _harness()
    _start_session(harness)

    harness.controller.on_permission_changed("denied")

    assert harness.controller.session_id is None
    assert harness.controller.state == "unavailable"


def test_close_scrubs_active_and_queued_playout_when_adapter_close_fails() -> None:
    harness = _harness()
    _start_session(harness)
    assert harness.controller.accept_frame(_announcement_frame(harness, sequence=1))
    assert harness.controller.accept_frame(_announcement_frame(harness, sequence=2))
    active = harness.controller._local_active_playout
    queued = harness.controller._local_announcement_queue[0]
    assert active is not None
    harness.speech.close = lambda: _raise(RuntimeError("already closed"))

    harness.controller.close()

    assert active["payload"]["text"] == ""
    assert queued["text"] == ""
    assert harness.controller.session_id is None
    assert harness.controller._closed
