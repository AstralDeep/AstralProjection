"""Exercises native token renewal through real registration and window lifecycle callbacks.
All identity responses, clocks, transport starts and persistence are isolated test inputs.
"""

import base64
from copy import deepcopy
import json
import threading
from threading import Thread as NativeThread
from types import SimpleNamespace
import uuid

import pytest
from PySide6.QtCore import QSettings
from PySide6.QtWidgets import QApplication, QLineEdit

from astral_client import app as appmod, auth, protocol
from astral_client.protocol import LocalOperationSubmission, OrchestratorClient
from astral_client.rest import RestError
from test_conversation_continuity_060 import CHAT, COMMIT, HYDRATION, _snapshot


def token(subject='alice', revision='old'):
    claims = {'iss': 'https://identity.invalid/realm', 'sub': subject, 'jti': revision}
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
    return f'test.{body}.signature'


def session(subject='alice', revision='old'):
    return auth.Session.from_response(
        {'access_token': token(subject, revision), 'refresh_token': 'synthetic-refresh', 'expires_in': 900},
        token_url='https://identity.invalid/token', client_id='astral-desktop')


class LocalClient(OrchestratorClient):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.registrations = []
        self.events = []

    def start(self):
        self._worker_running = True
        self.registrations.append(self._register_frame())

    def _start_worker_locked(self):
        self._worker_running = True

    def request_reconnect(self):
        self.start()

    def renew_credentials(self, token):
        renewed = super().renew_credentials(token)
        if renewed:
            self.start()
        return renewed

    def send_event(self, action, payload, session_id=None, **kwargs):
        self.events.append((action, payload, session_id))


@pytest.fixture
def clock(monkeypatch):
    values = SimpleNamespace(wall=1000.0, monotonic=500.0)
    monkeypatch.setattr(auth, 'time', SimpleNamespace(
        time=lambda: values.wall, monotonic=lambda: values.monotonic))
    return values


@pytest.fixture
def win(qapp, monkeypatch, tmp_path, clock):
    settings = QSettings(str(tmp_path / 'settings.ini'), QSettings.Format.IniFormat)
    monkeypatch.setattr(appmod, 'QSettings', lambda *a, **kw: settings)
    monkeypatch.setattr(protocol, 'QSettings', lambda *a, **kw: settings)
    monkeypatch.setattr(appmod, 'OrchestratorClient', LocalClient)
    monkeypatch.setattr(appmod.MainWindow, '_start_integrity_check', lambda self: None)
    monkeypatch.setattr(appmod.MainWindow, '_init_workspace', lambda self: None)
    monkeypatch.setenv('ASTRAL_WIN_AGENT', '0')
    current = session()
    window = appmod.MainWindow('ws://127.0.0.1:9/ws', current.access_token, session=current, connect=False)
    window._byo_enabled = False
    window.client.start()
    window._on_status('connected')
    yield window
    window.close()


@pytest.fixture
def workers(monkeypatch, win):
    queued = []
    monkeypatch.setattr(appmod.threading, 'Thread', lambda *, target, **kwargs:
                        SimpleNamespace(start=lambda: queued.append(target)))
    return queued


@pytest.fixture
def refresh(monkeypatch):
    calls = []
    def exchange(*args, **kwargs):
        calls.append((args, kwargs))
        return {'access_token': token(revision='renewed'), 'refresh_token': 'synthetic-rotated', 'expires_in': 900}
    monkeypatch.setattr(auth, '_post_form', exchange)
    return calls


def advance(clock, seconds):
    clock.wall += seconds
    clock.monotonic += seconds


def hydrate(win, *, components=None, transcript=None):
    win.active_chat = CHAT
    win.canvas.ctx.chat_id = CHAT
    win._continuity.activate_chat(CHAT)
    connection = win.client.connection_generation
    request = win.client.begin_conversation_request('hydration', CHAT)
    win._continuity.bind_connection(connection)
    win._continuity.open_request('hydration', request)
    frame = _snapshot(connection=connection, request=request)
    if components is not None:
        frame['canvas']['components'] = components
    if transcript is not None:
        frame['transcript'] = transcript
    win._on_message(frame)
    return frame


def test_proactive_renewal_registers_current_owner_and_resumes_without_losing_draft(
        win, workers, clock, refresh):
    component = {'type': 'input', 'component_id': 'editable', 'label': 'Result', 'value': 'server'}
    frame = hydrate(win, components=[component])
    field = win.canvas._by_id['editable'].findChild(QLineEdit)
    field.setText('edited locally')
    field.setCursorPosition(4)
    win._input.setText('next unsent prompt')
    win._stage_existing({'attachment_id': 'synthetic-file', 'filename': 'retained.txt', 'category': 'text'})
    attachments = deepcopy(win._attachments)
    owner = win._resume_store.storage_key
    previous = win.client
    old_generation = previous.connection_generation
    current = win._auth_session
    advance(clock, 840)
    win._refresh_expiring_session()
    assert len(workers) == 1 and win._auth_session is current
    assert current.access_token == token()
    workers.pop()()
    assert len(refresh) == 1
    registration = win.client.registrations[-1]
    assert registration['token'] == token(revision='renewed')
    assert registration['resume']['active_chat_id'] == CHAT
    assert registration['connection_generation'] != old_generation
    assert registration['device']['console_contract'] == 'console/v2'
    assert 'guidance_selection_v1' in registration['capabilities']
    assert registration['device']['voice'] == win._voice_audio.capability()
    assert win._resume_store.storage_key == owner and win.active_chat == CHAT
    assert win._input.text() == 'next unsent prompt' and win._attachments == attachments
    assert win._voice_controller.transport is win.client
    assert current.access_token == token() and current.refresh_token == 'synthetic-refresh'
    assert win._current_token() == token(revision='renewed')
    assert win.canvas._by_id['editable'].findChild(QLineEdit) is field
    win._on_status('connected')
    frame['snapshot_id'] = str(uuid.uuid4())
    frame['connection_generation'] = win.client.connection_generation
    frame['request_generation'] = win.client.request_generation
    win._on_message(frame)
    assert win._rendered_snapshot is win._continuity.committed_snapshot
    assert win._rendered_snapshot.request_generation == frame['request_generation']
    assert win._rendered_snapshot.connection_generation == frame['connection_generation']
    assert win.canvas._by_id['editable'].findChild(QLineEdit) is field
    assert field.text() == 'edited locally' and field.cursorPosition() == 4
    assert win._input.text() == 'next unsent prompt' and win._attachments == attachments
    assert win._auth_refresh_timer.isActive()
    assert not any(row[0] == 'chat_message' for row in win.client.events)


def test_refresh_triggers_are_single_flight_and_ws_failure_shares_attempt(win, workers, clock, refresh):
    advance(clock, 840)
    win._refresh_expiring_session()
    win._refresh_expiring_session()
    win._begin_silent_refresh()
    assert len(workers) == 1
    workers.pop()()
    assert len(refresh) == 1
    assert len(win.client.registrations) == 2


@pytest.mark.parametrize('transition', ['close', 'signout', 'owner', 'login', 'cancel'])
def test_real_session_rotation_cannot_cross_lifecycle(win, workers, clock, refresh, monkeypatch, transition):
    old = win._auth_session
    initial = dict(vars(old))
    advance(clock, 840)
    win._refresh_expiring_session()
    pending = workers.pop()
    if transition == 'close':
        win.close()
    elif transition == 'signout':
        monkeypatch.setattr(appmod.QMessageBox, 'question', lambda *a: appmod.QMessageBox.StandardButton.Yes)
        monkeypatch.setattr(appmod.QTimer, 'singleShot', lambda *a: None)
        win._sign_out()
    elif transition == 'owner':
        changed = session('bob', 'replacement')
        win._apply_login(changed.access_token, changed)
    else:
        win.begin_login(lambda cancel: (token('bob'), session('bob')))
        if transition == 'cancel':
            monkeypatch.setattr(win, '_login_retry_prompt', lambda *_: None)
            win.cancel_login()
    generation, current, client = win._auth_generation, win._auth_session, win.client
    prompts = []
    monkeypatch.setattr(win, '_prompt_reauth', lambda: prompts.append(True))
    pending()
    assert vars(old) == initial
    assert win._auth_generation == generation and win._auth_session is current and win.client is client
    assert not prompts and not win._silent_refresh_active


def test_generation_match_alone_cannot_accept_a_different_session(win, workers, clock, refresh):
    advance(clock, 840)
    win._refresh_expiring_session()
    pending = workers.pop()
    replacement = session('bob')
    win._auth_session = replacement
    current_token = win._token
    pending()
    assert win._auth_session is replacement and win._token == current_token


def test_duplicate_completion_cannot_reconnect_twice(win, workers, clock, refresh):
    advance(clock, 840)
    win._refresh_expiring_session()
    pending = workers.pop()
    pending()
    client = win.client
    generation = win._auth_generation
    pending()
    assert win.client is client and win._auth_generation == generation


def test_refresh_failures_stop_at_two_and_prompt_once(win, workers, clock, monkeypatch):
    calls, prompts = [], []
    monkeypatch.setattr(auth, '_post_form', lambda *a, **kw: calls.append(True) or {})
    monkeypatch.setattr(win, '_prompt_reauth', lambda: prompts.append(True))
    advance(clock, 840)
    win._refresh_expiring_session()
    workers.pop()()
    assert win._auth_refresh_timer.isActive() and win._auth_refresh_timer.interval() == 10_000
    win._refresh_expiring_session()
    workers.pop()()
    assert len(calls) == 2 and prompts == [True]
    assert not win._auth_refresh_timer.isActive()
    for _ in range(5):
        win._refresh_expiring_session()
    assert workers == [] and prompts == [True]


@pytest.mark.parametrize('operation', ['upload', 'download', 'audit'])
def test_expired_rest_request_is_not_sent(win, workers, clock, monkeypatch, tmp_path, operation):
    calls, audit = [], []
    monkeypatch.setattr(appmod.rest, 'upload_attachment', lambda *a: calls.append(a))
    monkeypatch.setattr(appmod.rest, 'fetch_bytes', lambda *a: calls.append(a))
    monkeypatch.setattr(appmod.rest, 'fetch_json', lambda *a: calls.append(a))
    win._audit_loaded.connect(audit.append)
    advance(clock, 901)
    if operation == 'upload':
        win._stage_upload(str(tmp_path / 'must-not-be-read.txt'))
    elif operation == 'download':
        monkeypatch.setattr(appmod.QFileDialog, 'getSaveFileName', lambda *a: (str(tmp_path / 'must-not-exist.txt'), ''))
        win._download('/api/result', 'result.txt')
    else:
        win._audit_dialog = appmod.AuditDialog(win, win._query_audit)
        win._query_audit({}, True)
    workers.pop()()
    assert calls == []
    if operation == 'upload':
        assert win._attachments[-1]['status'] == 'failed'
        assert 'Retry' in win._banner.text()
    elif operation == 'download':
        assert not (tmp_path / 'must-not-exist.txt').exists()
    else:
        assert audit[-1]['rows'] == [] and 'Retry' in audit[-1]['error']


def test_upload_401_is_never_replayed(win, workers, tmp_path, monkeypatch):
    calls = []
    path = tmp_path / 'test.txt'
    path.write_text('synthetic attachment')
    def denied(*args):
        calls.append(args)
        raise RestError(401, 'synthetic unauthorized')
    monkeypatch.setattr(appmod.rest, 'upload_attachment', denied)
    win._stage_upload(str(path))
    workers.pop()()
    assert len(calls) == 1 and workers == []
    assert win._attachments[-1]['status'] == 'failed'


def test_replacement_drops_every_old_client_callback(win):
    old = win.client
    pending = LocalOperationSubmission(str(uuid.uuid4()), COMMIT, 'chat_message', CHAT)
    assert win._project_local_submission(pending)
    win._reconnect(token(revision='replacement'))
    win._banner.setText('unchanged')
    before = dict(win._pending_submissions_by_id)
    old.message.emit({'type': 'error', 'message': 'stale old account error'})
    old.status.emit('closed:stale')
    old.submission.emit(LocalOperationSubmission(str(uuid.uuid4()), HYDRATION, 'chat_message', CHAT))
    old.submission_dropped.emit(pending)
    old.connection_generation_changed.emit(str(uuid.uuid4()))
    ack = protocol.QueuedReplayAcknowledgement()
    old.queued_replay_preparation.emit(None, ack)
    assert win._banner.text() == 'unchanged'
    assert win._pending_submissions_by_id == before
    assert not ack.ready.is_set()
    assert win._voice_controller.transport is win.client


def test_pending_projection_survives_same_owner_refresh_without_replaying_turn(win, workers, clock, refresh):
    hydrate(win)
    pending = LocalOperationSubmission(str(uuid.uuid4()), COMMIT, 'chat_message', CHAT)
    win._project_local_submission(pending)
    win._turn_active = True
    advance(clock, 840)
    win._refresh_expiring_session()
    workers.pop()()
    win._on_status('reconnecting:1')
    assert win._pending_submissions_by_id[pending.submission_id] is pending
    assert win._pending_submissions_by_generation[COMMIT] is pending
    assert win._turn_active
    assert not any(row[0] == 'chat_message' for row in win.client.events)


def test_identical_transcript_hydration_retains_embedded_control(win, workers, clock, refresh, qapp):
    frame = _snapshot()
    frame['transcript'][0]['parts'] = [{'type': 'components', 'components': [
        {'type': 'input', 'component_id': 'transcript-input', 'label': 'Answer', 'value': 'server'}]}]
    frame = hydrate(win, transcript=frame['transcript'])
    field = win.rail._inner.findChild(QLineEdit)
    field.setText('unsubmitted transcript edit')
    field.setCursorPosition(6)
    win.show()
    field.setFocus()
    qapp.processEvents()
    assert QApplication.focusWidget() is field
    advance(clock, 840)
    win._refresh_expiring_session()
    workers.pop()()
    win._on_status('connected')
    frame['snapshot_id'] = str(uuid.uuid4())
    frame['connection_generation'] = win.client.connection_generation
    frame['request_generation'] = win.client.request_generation
    win._on_message(frame)
    assert win._rendered_snapshot is win._continuity.committed_snapshot
    assert win._rendered_snapshot.request_generation == frame['request_generation']
    assert win._rendered_snapshot.connection_generation == frame['connection_generation']
    assert win.rail._inner.findChild(QLineEdit) is field
    assert field.text() == 'unsubmitted transcript edit' and field.cursorPosition() == 6
    assert QApplication.focusWidget() is field


@pytest.mark.parametrize('change', ['semantic', 'owner', 'context', 'theme', 'clear', 'add', 'note'])
def test_transcript_cache_never_masks_authoritative_changes(win, change):
    frame = _snapshot()
    frame['transcript'][0]['parts'] = [{'type': 'components', 'components': [
        {'type': 'input', 'component_id': 'transcript-input', 'value': 'server'}]}]
    messages = protocol.decode_semantic_transcript(frame['transcript'])
    context = win.canvas.ctx
    win.rail.replace_semantic(messages, context)
    old = win.rail._inner.findChild(QLineEdit)
    old.setText('local edit')
    if change == 'semantic':
        frame['transcript'][0]['parts'][0]['components'][0]['value'] = 'updated server'
        messages = protocol.decode_semantic_transcript(frame['transcript'])
    elif change == 'owner':
        win._reconnect(token('bob'))
    elif change == 'context':
        context = appmod.RenderContext(emit=lambda *_: None)
    elif change == 'theme':
        prior = dict(appmod.T.PALETTE)
        appmod.T.PALETTE['primary'] = '#abcdef'
    elif change == 'clear':
        win.rail.clear()
    elif change == 'add':
        win.rail.add('assistant', 'new local row')
    else:
        win.rail.add_note('new status note')
    try:
        win.rail.replace_semantic(messages, context)
        current = [w for w in win.rail._inner.findChildren(QLineEdit) if w is not old]
        assert current and current[-1].text() == ('updated server' if change == 'semantic' else 'server')
    finally:
        if change == 'theme':
            appmod.T.PALETTE.clear()
            appmod.T.PALETTE.update(prior)


def test_queued_old_owner_callbacks_are_rejected_after_replacement(win, qapp, monkeypatch):
    old, bridge = win.client, win._transport_bridge
    assert bridge.thread() is qapp.thread()
    acknowledgement = protocol.QueuedReplayAcknowledgement()
    submission = LocalOperationSubmission(str(uuid.uuid4()), COMMIT, 'chat_message', CHAT)
    preparation = protocol.QueuedReplayPreparation(old.connection_generation, submission, 'commit')
    def queued():
        old.message.emit({'type': 'history_list', 'chats': [{'chat_id': CHAT, 'title': 'Old private title'}]})
        old.message.emit({'type': 'chrome_menu', 'items': [{'label': 'Old private account'}]})
        old.message.emit({'type': 'rote_config', 'device_profile': {}})
        old.status.emit('closed:old private error')
        old.submission.emit(submission)
        old.submission_dropped.emit(submission)
        old.connection_generation_changed.emit(str(uuid.uuid4()))
        old.queued_replay_preparation.emit(preparation, acknowledgement)
    worker = threading.Thread(target=queued)
    worker.start()
    worker.join(timeout=2)
    assert not worker.is_alive() and not acknowledgement.ready.is_set()
    win._reconnect(token('bob'))
    calls = []
    for name in ('_on_message', '_on_status', '_project_local_submission',
                 '_discard_local_submission', '_voice_connection_changed', '_prepare_queued_replay'):
        monkeypatch.setattr(win, name, lambda *args: calls.append(args))
    qapp.processEvents()
    assert not calls and not win._pending_submissions_by_id
    assert acknowledgement.ready.is_set() and not acknowledgement.accepted
    win.client.message.emit({'type': 'current-owner'})
    assert calls == [({'type': 'current-owner'},)]


def test_current_transport_bridge_routes_all_owned_signals_and_stops_on_signout(win, monkeypatch):
    routes = []
    for name in ('_on_message', '_on_status', '_project_local_submission',
                 '_discard_local_submission', '_voice_connection_changed', '_prepare_queued_replay'):
        monkeypatch.setattr(win, name, lambda *args, route=name: routes.append((route, args)))
    client = win.client
    submission = LocalOperationSubmission(str(uuid.uuid4()), COMMIT, 'chat_message', CHAT)
    preparation = protocol.QueuedReplayPreparation(client.connection_generation, submission, 'commit')
    acknowledgement = protocol.QueuedReplayAcknowledgement()
    client.message.emit({'type': 'current'})
    client.status.emit('connected')
    client.submission.emit(submission)
    client.submission_dropped.emit(submission)
    client.connection_generation_changed.emit(client.connection_generation)
    client.queued_replay_preparation.emit(preparation, acknowledgement)
    assert [name for name, _ in routes] == [
        '_on_message', '_on_status', '_project_local_submission', '_discard_local_submission',
        '_voice_connection_changed', '_prepare_queued_replay']
    win._stop_auth()
    client.message.emit({'type': 'after-signout'})
    client.status.emit('connected')
    assert len(routes) == 6


def test_stale_replay_generation_cannot_roll_back_reducer(win):
    previous = win.client.connection_generation
    win.client.start()
    win._on_status('connected')
    current = win._continuity.connection_generation
    acknowledgement = protocol.QueuedReplayAcknowledgement()
    submission = LocalOperationSubmission(str(uuid.uuid4()), COMMIT, 'chat_message', CHAT)
    preparation = protocol.QueuedReplayPreparation(previous, submission, 'commit')
    win._prepare_queued_replay(preparation, acknowledgement)
    assert acknowledgement.ready.is_set() and not acknowledgement.accepted
    assert win._continuity.connection_generation == current
    assert not win._pending_submissions_by_id


def test_reconnect_worker_failure_settles_refresh_without_leaking_error(win, workers, clock, refresh, monkeypatch):
    def failed(token):
        raise RuntimeError('synthetic-private-credential')
    monkeypatch.setattr(win.client, 'renew_credentials', failed)
    advance(clock, 840)
    win._refresh_expiring_session()
    workers.pop()()
    assert not win._silent_refresh_active and not win._auth_refresh_timer.isActive()
    assert 'Restart the app' in win._banner.text()
    assert 'synthetic-private' not in win._banner.text()


def test_rejected_refreshed_credentials_do_not_reset_retry_budget(win, workers, refresh, monkeypatch):
    prompts = []
    monkeypatch.setattr(win, '_prompt_reauth', lambda: prompts.append(True))
    for expected in (1, 2):
        win.client._auth_hold = True
        win._on_status('auth_required:expired')
        assert len(workers) == 1
        workers.pop()()
        win._on_status('connected')
        assert win._reauth_tries == expected
    win.client._auth_hold = True
    win._on_status('auth_required:expired')
    assert len(refresh) == 2 and workers == [] and prompts == [True]
    assert not win._auth_refresh_timer.isActive()
    win.client._auth_hold = False
    win.client._connected = True
    win.client._authenticated_revision = win.client._auth_revision
    win._on_message({'type': 'rote_config', 'device_profile': {}})
    assert win._reauth_tries == 0 and win._auth_refresh_timer.isActive()


def test_same_owner_renewal_retires_host_remote_and_pending_voice_authority(
        win, workers, clock, refresh, monkeypatch):
    host, remote = [], []
    monkeypatch.setattr(win._byo, 'on_transport_disconnected', lambda: host.append(True))
    monkeypatch.setattr(win._remote, 'on_transport_status', remote.append)
    win._byo_enabled = True
    win._win_agent_registered = True
    controller = win._voice_controller
    controller._pending_chat_activation = ('voice_session_start', 'synthetic-pending')
    controller._activation_id = 'synthetic-pending'
    epoch = controller._activation_epoch
    assert controller.control_binding_connection is None
    advance(clock, 840)
    win._refresh_expiring_session()
    workers.pop()()
    assert host == [True] and remote[0] == 'reconnecting:1'
    assert not win._win_agent_registered
    assert controller._activation_epoch > epoch
    assert controller._pending_chat_activation is None and controller._activation_id is None
    win._byo_enabled = False


@pytest.mark.parametrize('replace', [False, True])
def test_reconnection_revokes_voice_binding_and_media_preserving_recovery_fence(
        win, workers, clock, refresh, replace):
    from test_voice_lifecycle_065 import _controller, SESSION
    win._voice_controller.close()
    controller, _, _, media = _controller()
    controller.handle_action('voice_session_start')
    win._voice_controller = controller
    controller.transport = win.client
    old = win.client
    previous_audio_stops = controller.audio.stopped
    if replace:
        win._reconnect(token(revision='replacement'))
    else:
        advance(clock, 840)
        win._refresh_expiring_session()
        workers.pop()()
    assert (win.client is old) is (not replace)
    assert controller.transport is win.client
    assert controller.control_binding is None and controller.control_binding_connection is None
    assert controller._remote_recovery['session_id'] == SESSION
    assert controller._remote_recovery['generation'] == 2
    assert ('close',) in media.calls and controller.audio.stopped > previous_audio_stops


@pytest.fixture
def audit_response(monkeypatch):
    monkeypatch.setattr(appmod.rest, 'fetch_json', lambda *args:
                        {'items': [{'description': 'Current owner audit entry'}], 'next_cursor': None})


@pytest.mark.parametrize('transition', ['owner', 'stop'])
def test_audit_retirement_clears_private_rows_and_rejects_late_workers(
        win, workers, audit_response, transition):
    win._open_audit()
    old = win._audit_dialog
    old.add_page([{'description': 'Old private audit row'}], 'private-cursor')
    old._search.setText('private filter')
    delayed = workers.pop()
    if transition == 'owner':
        win._reconnect(token('bob'))
    else:
        win._stop_auth()
    assert win._audit_dialog is None and win._audit_request is None
    assert old._table.rowCount() == 0 and old._search.text() == ''
    assert old._status_lbl.text() == '' and not old.isVisible()
    if transition == 'owner':
        win._open_audit()
        current = win._audit_dialog
        current._status_lbl.setText('New owner request')
        delayed()
        assert current._table.rowCount() == 0 and current._status_lbl.text() == 'New owner request'
        workers.pop()()
        assert current._table.rowCount() == 1
    else:
        delayed()
        win._open_audit()
        win._query_audit({}, True)
        assert win._audit_dialog is None and workers == []


def test_queued_audit_result_cannot_cross_owner_switch(win, workers, audit_response, qapp):
    win._open_audit()
    previous = win._audit_dialog
    worker = NativeThread(target=workers.pop())
    worker.start()
    worker.join(timeout=2)
    assert not worker.is_alive() and previous._table.rowCount() == 0
    win._reconnect(token('bob'))
    win._open_audit()
    current = win._audit_dialog
    qapp.processEvents()
    assert current is not previous and current._table.rowCount() == 0
    workers.pop()()
    assert current._table.rowCount() == 1


def test_audit_latest_filter_and_exact_dialog_are_required(win, workers, audit_response):
    win._open_audit()
    dialog = win._audit_dialog
    previous = workers.pop()
    win._query_audit({'q': 'latest'}, True)
    workers.pop()()
    assert dialog._table.rowCount() == 1
    previous()
    assert dialog._table.rowCount() == 1
    win._query_audit({}, False)
    pending = workers.pop()
    replacement = appmod.AuditDialog(win, win._query_audit)
    win._audit_dialog = replacement
    pending()
    assert replacement._table.rowCount() == 0
    dialog.close()
    dialog.deleteLater()


def test_same_owner_renewal_preserves_inflight_audit_request(win, workers, audit_response, clock, refresh):
    win._open_audit()
    dialog = win._audit_dialog
    pending = workers.pop()
    advance(clock, 840)
    win._refresh_expiring_session()
    workers.pop()()
    pending()
    assert win._audit_dialog is dialog and dialog._table.rowCount() == 1
