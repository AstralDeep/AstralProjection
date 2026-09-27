"""Tests the authentication session's token response validation and renewal deadlines.
Synthetic responses and independent clocks exercise expiry and refresh-token rotation.
"""

from copy import copy
from types import SimpleNamespace

import pytest


from astral_client import auth


@pytest.fixture
def clock(monkeypatch):
    value = SimpleNamespace(wall=1000.0, monotonic=500.0)
    monkeypatch.setattr(auth, 'time', SimpleNamespace(
        time=lambda: value.wall, monotonic=lambda: value.monotonic))
    return value


def create(**values):
    return auth.Session.from_response(
        {'access_token': 'synthetic-access', 'refresh_token': 'synthetic-refresh',
         'expires_in': 900, **values}, token_url='https://identity.invalid/token', client_id='desktop')


def test_initial_deadlines_and_early_schedule(clock):
    session = create()
    assert session.expires_at == 1900
    assert session.monotonic_expires_at == 1400
    assert session.remaining() == 900
    assert session.refresh_margin == 60
    assert session.refresh_delay_ms() == 60_000
    clock.wall += 839
    clock.monotonic += 839
    assert session.refresh_delay_ms() == 1000
    clock.wall += 1
    clock.monotonic += 1
    assert session.refresh_delay_ms() == 0


@pytest.mark.parametrize('lifetime,margin,delay', [
    (60, 6, 54_000), (10, 1, 9000), (0.5, 0.05, 450),
    (31_536_000, 60, 60_000),
])
def test_bounded_proportional_timer(clock, lifetime, margin, delay):
    session = create(expires_in=lifetime)
    assert session.refresh_margin == margin
    assert session.refresh_delay_ms() == delay


@pytest.mark.parametrize('lifetime', [
    True, False, None, 0, -1, float('nan'), float('inf'), -float('inf'),
    '900', '', [], {}, 31_536_001, 10 ** 1000,
])
def test_invalid_expiry_rejected(clock, lifetime):
    with pytest.raises(ValueError, match='expiry'):
        create(expires_in=lifetime)


@pytest.mark.parametrize('token', [None, '', ' ', 1, False, [], {}])
def test_invalid_access_token_rejected(clock, token):
    with pytest.raises(ValueError, match='credentials'):
        create(access_token=token)


@pytest.mark.parametrize('token', ['', ' ', 1, False, [], {}])
def test_invalid_rotated_refresh_token_rejected(clock, token):
    with pytest.raises(ValueError, match='credentials'):
        create(refresh_token=token)


def test_missing_expiry_preserves_legacy_compatibility(clock):
    session = auth.Session.from_response({'access_token': 'synthetic-access'},
        token_url='https://identity.invalid/token', client_id='desktop',
        refresh_token='synthetic-existing')
    assert session.refresh_token == 'synthetic-existing'
    assert session.remaining() is None and session.refresh_delay_ms() is None


def test_missing_refresh_token_has_no_timer_or_network(clock, monkeypatch):
    session = create(refresh_token=None)
    monkeypatch.setattr(auth, '_post_form', lambda *a, **kw: pytest.fail('network invoked'))
    assert session.refresh_delay_ms() is None
    assert session.refresh() is None


@pytest.mark.parametrize('wall_delta,mono_delta,remaining', [
    (901, 0, -1), (0, 901, -1), (-3600, 901, -1), (20, 10, 880),
])
def test_wall_and_monotonic_clocks_do_not_extend_validity(clock, wall_delta, mono_delta, remaining):
    session = create()
    clock.wall += wall_delta
    clock.monotonic += mono_delta
    assert session.remaining() == remaining
    assert session.refresh_delay_ms() == (0 if remaining < 0 else 60_000)


def test_clock_overflow_rejected(clock):
    clock.wall = float('inf')
    with pytest.raises(ValueError, match='expiry'):
        create()


@pytest.mark.parametrize('rotated', [True, False])
def test_refresh_copy_rotates_without_mutating_original(clock, monkeypatch, rotated):
    original = create()
    initial = dict(vars(original))
    candidate = copy(original)
    calls = []
    response = {'access_token': 'synthetic-fresh', 'expires_in': 1200}
    if rotated:
        response['refresh_token'] = 'synthetic-rotated'

    def exchange(url, fields, timeout):
        calls.append((url, fields, timeout))
        return response

    monkeypatch.setattr(auth, '_post_form', exchange)
    clock.wall += 840
    clock.monotonic += 840
    assert candidate.refresh() == 'synthetic-fresh'
    assert vars(original) == initial
    assert candidate.refresh_token == ('synthetic-rotated' if rotated else 'synthetic-refresh')
    assert candidate.remaining() == 1200
    assert calls == [('https://identity.invalid/token', {
        'grant_type': 'refresh_token', 'refresh_token': 'synthetic-refresh',
        'client_id': 'desktop'}, 15)]


@pytest.mark.parametrize('response', [
    {'access_token': 'synthetic-fresh', 'expires_in': 0},
    {'access_token': '', 'refresh_token': 'synthetic-rotated', 'expires_in': 900},
    {'access_token': 'synthetic-fresh', 'refresh_token': False, 'expires_in': 900},
    None, [],
])
def test_failed_response_never_partially_changes_session(clock, monkeypatch, response):
    session = create()
    initial = dict(vars(session))
    monkeypatch.setattr(auth, '_post_form', lambda *a, **kw: response)
    assert session.refresh() is None
    assert vars(session) == initial


def test_failed_exchange_preserves_credentials(clock, monkeypatch):
    session = create()
    initial = dict(vars(session))

    def exchange(*args, **kwargs):
        raise TimeoutError('synthetic request timeout')

    monkeypatch.setattr(auth, '_post_form', exchange)
    assert session.refresh() is None
    assert vars(session) == initial


@pytest.mark.parametrize('exception', [RuntimeError, ValueError, TimeoutError])
def test_refresh_failure_does_not_log_exception_secrets(clock, monkeypatch, caplog, exception):
    session = create()

    def exchange(*args, **kwargs):
        raise exception('synthetic-private-credential-sentinel')

    monkeypatch.setattr(auth, '_post_form', exchange)
    assert session.refresh() is None
    assert 'token refresh failed' in caplog.text
    assert 'synthetic-private-credential-sentinel' not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)
