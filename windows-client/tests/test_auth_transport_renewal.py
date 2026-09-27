"""Exercises credential renewal and worker retirement without external sockets or identity providers.
The existing registration/replay protocol is driven at its asynchronous race boundaries.
"""

import asyncio
from concurrent.futures import Future
import json
from types import SimpleNamespace

import pytest

from astral_client import protocol
from astral_client.protocol import OrchestratorClient


CHAT = '11111111-1111-4111-8111-111111111111'
CONNECTION = '22222222-2222-4222-8222-222222222222'


@pytest.fixture
def client(qapp, monkeypatch):
    value = OrchestratorClient('ws://127.0.0.1:9/ws', 'synthetic-old')
    value._worker_running = True
    value.connection_generation = CONNECTION
    monkeypatch.setattr(value, '_request_socket_close', lambda *args: None)
    yield value
    value.stop()


def test_renewal_preserves_fifo_identity_and_voice_outbox(client):
    client.configure_resume(CHAT)
    first = client.send_chat('first', CHAT)
    second = client.send_chat('second', CHAT)
    queued = list(client._pending)
    voices = client._voice_pending
    voices['synthetic-pending'] = object()
    assert client.renew_credentials('synthetic-new')
    assert list(client._pending) == queued and client._voice_pending is voices
    registration = client._register_frame()
    assert registration['token'] == 'synthetic-new'
    assert registration['resume']['active_chat_id'] == CHAT
    assert [json.loads(frame)['submission_id'] for frame in queued] == [first.submission_id, second.submission_id]


@pytest.mark.parametrize('token', [None, '', ' ', 'a\nb', 'x' * 16385, 1])
def test_invalid_renewal_does_not_change_state(client, token):
    assert not client.renew_credentials(token)
    assert client.token == 'synthetic-old' and client._auth_revision == 0


def test_stopped_client_cannot_be_revived(client, monkeypatch):
    starts = []
    monkeypatch.setattr(client, '_start_worker_locked', lambda: starts.append(True))
    client.stop()
    client.start()
    assert not client.renew_credentials('forbidden')
    assert starts == [] and not client._restart_after_exit


def test_renewal_closes_only_captured_socket_when_worker_starts(client, monkeypatch):
    old_loop, old_socket, new_socket = object(), object(), object()
    client._worker_running = False
    client._loop, client._ws = old_loop, old_socket
    closes = []
    monkeypatch.setattr(client, '_request_socket_close', lambda *args: closes.append(args))
    def started():
        client._worker_running = True
        client._ws = new_socket
    monkeypatch.setattr(client, '_start_worker_locked', started)
    assert client.renew_credentials('new')
    assert closes == [(old_loop, old_socket)]
    client._loop, client._ws = None, None


@pytest.mark.parametrize('stop_after_renewal', [False, True])
def test_renewal_during_worker_exit_is_not_lost(client, monkeypatch, stop_after_renewal):
    client._auth_hold = True
    starts = []
    loop = asyncio.new_event_loop()
    close = loop.close
    def exiting():
        assert client.renew_credentials('renewed-during-exit')
        if stop_after_renewal:
            client.stop()
        close()
    monkeypatch.setattr(loop, 'close', exiting)
    monkeypatch.setattr(protocol.asyncio, 'new_event_loop', lambda: loop)
    monkeypatch.setattr(client, '_run_connections', lambda: None)
    monkeypatch.setattr(client, '_start_worker_locked', lambda: starts.append(client.token))
    client._run()
    assert starts == ([] if stop_after_renewal else ['renewed-during-exit'])
    assert not client._restart_after_exit


def test_cleanup_failure_still_settles_worker_state(client, monkeypatch):
    loop = asyncio.new_event_loop()
    close = loop.close
    def fail_close():
        close()
        raise RuntimeError('synthetic cleanup failure')
    monkeypatch.setattr(loop, 'close', fail_close)
    monkeypatch.setattr(protocol.asyncio, 'new_event_loop', lambda: loop)
    monkeypatch.setattr(client, '_run_connections', lambda: None)
    with pytest.raises(RuntimeError, match='cleanup'):
        client._run()
    assert not client._worker_running and client._loop is None


def test_worker_start_failure_is_bounded(client, monkeypatch):
    client._worker_running = False
    def failure():
        raise RuntimeError('synthetic start failure')
    monkeypatch.setattr(protocol.threading, 'Thread', lambda **kwargs: SimpleNamespace(start=failure))
    with pytest.raises(RuntimeError, match='start failure'):
        client.renew_credentials('new')
    assert not client._worker_running and not client._restart_after_exit


@pytest.mark.parametrize('renew', [False, True])
def test_socket_auth_failure_is_bound_to_registered_credential(client, monkeypatch, renew):
    statuses = []
    client.status.connect(statuses.append)
    class Socket:
        closed = False
        async def __aenter__(self):
            return self
        async def __aexit__(self, *args):
            return False
        async def send(self, frame):
            self.registration = json.loads(frame)
        async def close(self):
            self.closed = True
        def __aiter__(self):
            async def frames():
                if renew:
                    client.renew_credentials('new')
                yield json.dumps({'type': 'auth_required', 'reason': 'expired'})
            return frames()
    socket = Socket()
    monkeypatch.setattr(protocol.websockets, 'connect', lambda *args, **kwargs: socket)
    asyncio.run(client._main())
    assert socket.closed
    assert client.authentication_required is (not renew)
    assert any(row.startswith('auth_required:') for row in statuses) is (not renew)
    client._ws = None


def test_accepted_registration_requires_current_rote_config(client, monkeypatch):
    class Socket:
        async def __aenter__(self):
            return self
        async def __aexit__(self, *args):
            return False
        async def send(self, frame):
            pass
        def __aiter__(self):
            async def frames():
                assert client.connected and not client.authenticated
                yield json.dumps({'type': 'rote_config', 'device_profile': {}})
            return frames()
    socket = Socket()
    monkeypatch.setattr(protocol.websockets, 'connect', lambda *a, **kw: socket)
    asyncio.run(client._main())
    assert client.authenticated
    client.renew_credentials('new')
    assert not client.authenticated
    client._ws = None


def test_renewal_during_replay_preparation_retains_exact_submission(client):
    submission = client.send_chat('pending', CHAT)
    client.require_queued_replay_preparation()
    sent, attempts = [], []
    class Socket:
        async def send(self, frame):
            sent.append(json.loads(frame))
    socket = Socket()
    client._ws = socket
    def acknowledge(preparation, acknowledgement):
        attempts.append(preparation)
        if len(attempts) == 1:
            client.renew_credentials('new')
        acknowledgement.complete(True)
    client.queued_replay_preparation.connect(acknowledge)
    with pytest.raises(ConnectionError):
        asyncio.run(client._flush_pending(socket))
    assert sent == [] and len(client._pending) == 1
    client._register_frame()
    asyncio.run(client._flush_pending(socket))
    assert len(sent) == 1 and not client._pending
    assert sent[0]['submission_id'] == submission.submission_id
    assert sent[0]['request_generation'] == submission.request_generation
    client._ws = None


def test_renewal_during_send_does_not_drop_next_fifo_frame(client):
    first = client.send_chat('first', CHAT)
    second = client.send_chat('second', CHAT)
    sent = []
    class Socket:
        async def send(self, frame):
            sent.append(json.loads(frame))
            if len(sent) == 1:
                client.renew_credentials('new')
    socket = Socket()
    client._ws = socket
    with pytest.raises(ConnectionError):
        asyncio.run(client._flush_pending(socket))
    assert len(sent) == 1 and len(client._pending) == 1
    client._register_frame()
    asyncio.run(client._flush_pending(socket))
    assert [frame['submission_id'] for frame in sent] == [first.submission_id, second.submission_id]
    client._ws = None


def test_superseded_fast_send_requeues_once_before_socket_use(client, monkeypatch):
    sent, scheduled = [], []
    class Socket:
        async def send(self, frame):
            sent.append(frame)
    client._ws, client._loop, client._connected = Socket(), object(), True
    future = Future()
    monkeypatch.setattr(protocol.asyncio, 'run_coroutine_threadsafe', lambda coro, loop:
                        scheduled.append(coro) or future)
    submission = client.send_chat('pending', CHAT)
    client.renew_credentials('new')
    with pytest.raises(ConnectionError) as failure:
        asyncio.run(scheduled.pop())
    future.set_exception(failure.value)
    assert sent == [] and len(client._pending) == 1
    assert json.loads(client._pending[0])['submission_id'] == submission.submission_id
    client._ws, client._loop = None, None


def test_renewal_during_final_open_phase_never_announces_connected(client, monkeypatch):
    statuses, calls = [], []
    client.status.connect(statuses.append)
    async def flush(ws):
        calls.append(True)
        if len(calls) == 2:
            client.renew_credentials('new')
    monkeypatch.setattr(client, '_flush_pending', flush)
    with pytest.raises(ConnectionError):
        asyncio.run(client._finish_open(object()))
    assert not client.connected and 'connected' not in statuses


def test_intentional_renewal_does_not_emit_destructive_closed_status(client, monkeypatch):
    statuses = []
    client.status.connect(statuses.append)
    loop = asyncio.new_event_loop()
    client._loop = loop
    async def connection():
        client.renew_credentials('new')
    monkeypatch.setattr(client, '_main', connection)
    monkeypatch.setattr(client, '_interruptible_sleep', lambda *_: False)
    try:
        client._run_connections()
    finally:
        loop.close()
        client._loop = None
    assert not any(value.startswith('closed') for value in statuses)
    assert statuses == ['reconnecting:1']


@pytest.mark.parametrize('operation', ['ordinary', 'voice', 'activation', 'host'])
def test_closed_loop_closes_coroutine_and_preserves_only_ordinary_queue(client, monkeypatch, operation):
    import inspect
    scheduled, sent = [], []
    class Socket:
        async def send(self, frame):
            sent.append(frame)
    client._ws, client._loop, client._connected = Socket(), object(), True
    def rejected(coro, loop):
        scheduled.append(coro)
        raise RuntimeError('event loop is closed')
    monkeypatch.setattr(protocol.asyncio, 'run_coroutine_threadsafe', rejected)
    if operation == 'ordinary':
        client.send_chat('pending', CHAT)
    elif operation == 'voice':
        assert not client._send_voice_frame({'type': 'voice_control'})
    elif operation == 'activation':
        assert not client.send_correlated_new_chat(CHAT, CONNECTION)
    else:
        client.send_host_frame({'type': 'agent_status'})
    assert len(scheduled) == 1 and inspect.getcoroutinestate(scheduled[0]) == inspect.CORO_CLOSED
    assert sent == [] and len(client._pending) == (1 if operation == 'ordinary' else 0)
    client._ws, client._loop = None, None


@pytest.mark.parametrize('operation', ['voice', 'activation', 'host'])
def test_superseded_nonreplay_send_never_uses_retired_socket(client, monkeypatch, operation):
    sent, scheduled = [], []
    class Socket:
        async def send(self, frame):
            sent.append(frame)
    client._ws, client._loop, client._connected = Socket(), object(), True
    future = Future()
    monkeypatch.setattr(protocol.asyncio, 'run_coroutine_threadsafe', lambda coro, loop:
                        scheduled.append(coro) or future)
    if operation == 'voice':
        assert client._send_voice_frame({'type': 'voice_control'})
    elif operation == 'activation':
        assert client.send_correlated_new_chat(CHAT, CONNECTION)
    else:
        client.send_host_frame({'type': 'agent_status'})
    client.renew_credentials('new')
    with pytest.raises(ConnectionError) as failure:
        asyncio.run(scheduled.pop())
    future.set_exception(failure.value)
    assert not sent and not client._pending
    client._ws, client._loop = None, None


def test_renewal_during_voice_replay_stops_before_next_frame(client, monkeypatch):
    sent = []
    class Socket:
        async def send(self, frame):
            sent.append(json.loads(frame))
            client.renew_credentials('new')
    socket = Socket()
    client._ws = socket
    monkeypatch.setattr(client, '_pending_voice_frames', lambda: [{'turn': 'first'}, {'turn': 'second'}])
    with pytest.raises(ConnectionError):
        asyncio.run(client._resend_voice_pending(socket))
    assert sent == [{'turn': 'first'}]
    client._ws = None


@pytest.mark.parametrize('raises', [False, True])
def test_renewal_before_registration_does_not_hide_later_normal_close(client, monkeypatch, raises):
    statuses = []
    client.status.connect(statuses.append)
    loop = asyncio.new_event_loop()
    client._loop = loop
    class Socket:
        async def __aenter__(self):
            client.renew_credentials('new-during-handshake')
            return self
        async def __aexit__(self, *args):
            return False
        async def send(self, frame):
            assert json.loads(frame)['token'] == 'new-during-handshake'
        def __aiter__(self):
            async def frames():
                if raises:
                    raise ConnectionError('synthetic ordinary close')
                for value in []:
                    yield value
            return frames()
    monkeypatch.setattr(protocol.websockets, 'connect', lambda *a, **kw: Socket())
    monkeypatch.setattr(client, '_interruptible_sleep', lambda *_: False)
    try:
        client._run_connections()
    finally:
        loop.close()
        client._loop = None
    assert ('closed:synthetic ordinary close' if raises else 'closed:server') in statuses


def test_close_scheduling_failure_does_not_leak_coroutine(monkeypatch):
    import inspect
    scheduled = []
    class Socket:
        async def close(self):
            pass
    def rejected(coro, loop):
        scheduled.append(coro)
        raise RuntimeError('event loop is closed')
    monkeypatch.setattr(protocol.asyncio, 'run_coroutine_threadsafe', rejected)
    OrchestratorClient._request_socket_close(object(), Socket())
    assert inspect.getcoroutinestate(scheduled[0]) == inspect.CORO_CLOSED
