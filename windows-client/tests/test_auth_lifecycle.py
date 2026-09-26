"""Exercises authentication completions against account replacement, cancellation and shutdown.
The real window callbacks run with deterministic workers and no external identity provider.
"""

from types import SimpleNamespace

import pytest

from astral_client import app as appmod, auth
from test_message_routing import win as window_fixture  # noqa: F401


@pytest.fixture
def win(request):
    return request.getfixturevalue("window_fixture")


@pytest.fixture
def workers(monkeypatch):
    pending = []
    monkeypatch.setattr(appmod.threading, "Thread", lambda *, target, **kwargs:
                        SimpleNamespace(start=lambda: pending.append(target)))
    return pending


def session(token="fresh"):
    return SimpleNamespace(access_token=token, refresh_token=None, client_id="astral-desktop",
                           token_url="", refresh=lambda: token)


def confirm(monkeypatch, answer=None):
    monkeypatch.setattr(appmod.QMessageBox, "question", lambda *args:
                        appmod.QMessageBox.StandardButton.Yes if answer is None else answer)


@pytest.mark.parametrize("result", ["old-refresh", None])
@pytest.mark.parametrize("transition", ["close", "signout", "replace"])
def test_delayed_refresh_cannot_cross_auth_lifecycle(win, workers, monkeypatch, result, transition):
    win._auth_session = session(result)
    win._begin_silent_refresh()
    pending = workers.pop()
    prompts = []
    monkeypatch.setattr(win, "_prompt_reauth", lambda: prompts.append(True))
    if transition == "close":
        win.close()
    elif transition == "signout":
        confirm(monkeypatch)
        monkeypatch.setattr(appmod.QTimer, "singleShot", lambda *args: None)
        win._sign_out()
    else:
        win._apply_login("replacement", session("replacement"))
    client, token, current = win.client, win._token, win._auth_session
    pending()
    assert win.client is client and win._token == token and win._auth_session is current
    assert prompts == [] and not win._silent_refresh_active


@pytest.mark.parametrize("result", ["old-refresh", None])
def test_old_refresh_preserves_new_pending_login(win, workers, result):
    win._auth_session = session(result)
    win._begin_silent_refresh()
    old = workers.pop()
    win.begin_login(lambda cancel: ("replacement", session("replacement")))
    generation = win._auth_generation
    old()
    assert win._login_active and win._auth_generation == generation
    workers.pop()()
    assert win._token == "replacement" and not win._login_active


@pytest.mark.parametrize("failure", [False, True])
def test_current_refresh_delivers_success_or_failure(win, workers, monkeypatch, failure):
    def refresh():
        if failure:
            raise RuntimeError("synthetic refresh failure")
        return "fresh"
    win._auth_session = session()
    win._auth_session.refresh = refresh
    prompts = []
    monkeypatch.setattr(win, "_prompt_reauth", lambda: prompts.append(True))
    win._begin_silent_refresh()
    win._begin_silent_refresh()
    assert len(workers) == 1
    workers.pop()()
    assert prompts == ([True] if failure else [])
    assert win._token == ("dev-token" if failure else "fresh")


@pytest.mark.parametrize("transition", ["close", "replace"])
@pytest.mark.parametrize("failure", [False, True])
def test_interactive_reauth_completion_is_bound_to_attempt(win, workers, monkeypatch, transition, failure):
    def login(*args, **kwargs):
        if failure:
            raise RuntimeError("synthetic sign-in failure")
        return session("stale")
    confirm(monkeypatch)
    monkeypatch.setattr(auth, "oidc_login", login)
    win._login_params = {"authority": "https://identity.example/realm"}
    win._prompt_reauth()
    pending = workers.pop()
    cancel = win._login_cancel
    if transition == "close":
        win.close()
    else:
        win._apply_login("replacement", session("replacement"))
    client, token, current, banner = win.client, win._token, win._auth_session, win._banner.text()
    assert cancel.is_set()
    pending()
    assert win.client is client and win._token == token and win._auth_session is current
    assert win._banner.text() == banner


@pytest.mark.parametrize("failure", [False, True])
def test_current_interactive_reauth_and_duplicate_prompt(win, workers, monkeypatch, failure):
    seen = []
    def login(*args, **kwargs):
        seen.append(kwargs)
        if failure:
            raise RuntimeError("synthetic sign-in failure")
        return session()
    confirm(monkeypatch)
    monkeypatch.setattr(auth, "oidc_login", login)
    win._login_params = {"authority": "https://identity.example/realm", "bff": True}
    win._prompt_reauth()
    win._prompt_reauth()
    win._begin_silent_refresh()
    assert len(workers) == 1
    workers.pop()()
    assert seen[0]["bff_base"] == "http://127.0.0.1:9"
    assert not win._reauth_active
    if failure:
        assert "Sign-in failed" in win._banner.text()
    else:
        assert win._token == "fresh"


@pytest.mark.parametrize("close", [False, True])
def test_reauth_confirmation_cannot_outlive_window(win, workers, monkeypatch, close):
    def question(*args):
        if close:
            win.close()
            return appmod.QMessageBox.StandardButton.Yes
        return appmod.QMessageBox.StandardButton.No
    monkeypatch.setattr(appmod.QMessageBox, "question", question)
    win._login_params = {"authority": "https://identity.example/realm"}
    win._prompt_reauth()
    assert workers == [] and not win._reauth_active


@pytest.mark.parametrize("transition", ["cancel", "close", "replace"])
def test_successful_startup_login_after_invalidation_is_not_applied(win, workers, monkeypatch, transition):
    prompts = []
    monkeypatch.setattr(win, "_login_retry_prompt", prompts.append)
    win.begin_login(lambda cancel: ("stale", session("stale")))
    pending = workers.pop()
    if transition == "cancel":
        win.cancel_login()
    elif transition == "close":
        win.close()
    else:
        win._apply_login("replacement", session("replacement"))
    client, token = win.client, win._token
    pending()
    assert win.client is client and win._token == token
    assert prompts == (["cancelled"] if transition == "cancel" else [])


def test_shutdown_refuses_every_new_auth_entry(win, workers):
    win.close()
    client = win.client
    win._reconnect("forbidden")
    win._prompt_reauth()
    win._begin_silent_refresh()
    win.begin_login(lambda cancel: ("forbidden", None))
    assert workers == [] and win.client is client and win._token == "dev-token"
