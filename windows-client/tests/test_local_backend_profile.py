"""Exercises explicit local-server deployment with real HTTPS Keycloak authentication.
The profile keeps release and all-local developer restrictions independent.
"""

import json
from pathlib import Path

import pytest

from astral_client.deployment import DeploymentProfileError, parse_profile, resolve_startup


ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "deployment/local-backend-profile.json"


def local_profile():
    return json.loads(PROFILE.read_text(encoding="utf-8"))


@pytest.mark.parametrize("source", ["command_line", "persisted", "managed"])
def test_local_profile_uses_one_explicit_endpoint_and_normal_keycloak(source):
    selected = local_profile()
    startup = resolve_startup(
        ["--deployment-profile", str(PROFILE)] if source == "command_line" else [],
        resource_root=ROOT, expected_client_version="0.5.2", frozen=True,
        persisted_profile_json=json.dumps(selected) if source == "persisted" else None,
        environment=({"ASTRAL_MANAGED_DEPLOYMENT_PROFILE": str(PROFILE)} if source == "managed" else {}),
    )
    profile = startup.effective_profile.profile
    assert profile.distribution == "local_backend"
    assert profile.local_only
    assert profile.websocket_endpoint == "ws://127.0.0.1:8001/ws"
    assert profile.authority == "https://iam.ai.uky.edu/realms/Astral"
    assert profile.auth_mode == "keycloak_oidc_pkce"
    assert not profile.override_policy.development_defaults_allowed
    assert not profile.override_policy.configure_dialog_allowed
    assert profile.agent_connection.legacy_tools.disposition == "disabled"


@pytest.mark.parametrize("endpoint", [
    "ws://localhost:8001/ws", "ws://127.0.0.2:8001/ws", "wss://[::1]:8001/ws",
    "ws://test.localhost.:8001/ws",
])
def test_local_backend_accepts_loopback_hosts(endpoint):
    value = local_profile()
    value["websocket_endpoint"] = endpoint
    assert parse_profile(value).websocket_endpoint == endpoint


@pytest.mark.parametrize(("field", "value", "message"), [
    ("local_only", False, "loopback"),
    ("websocket_endpoint", "wss://sandbox.ai.uky.edu/ws", "loopback"),
    ("websocket_endpoint", "ws://192.168.1.2:8001/ws", "loopback"),
    ("websocket_endpoint", "ws://0.0.0.0:8001/ws", "loopback"),
    ("websocket_endpoint", "ws://[::]:8001/ws", "loopback"),
    ("websocket_endpoint", "ws://[0:0:0:0:0:0:0:0]:8001/ws", "loopback"),
    ("websocket_endpoint", "ws://[::0]:8001/ws", "loopback"),
    ("websocket_endpoint", "ws://[::%1]:8001/ws", "loopback"),
    ("authority", "http://iam.ai.uky.edu/realms/Astral", "HTTPS"),
    ("authority", "https://localhost/realms/Astral", "HTTPS"),
    ("auth_mode", "keycloak_bff", "PKCE"),
])
def test_local_backend_rejects_unsafe_or_ambiguous_connections(field, value, message):
    selected = local_profile()
    selected[field] = value
    with pytest.raises(DeploymentProfileError, match=message):
        parse_profile(selected)


@pytest.mark.parametrize("field", ["configure_dialog_allowed", "development_defaults_allowed"])
def test_local_backend_cannot_enable_auth_configuration_fallback(field):
    selected = local_profile()
    selected["override_policy"][field] = True
    with pytest.raises(DeploymentProfileError, match="fallback"):
        parse_profile(selected)


@pytest.mark.parametrize("legacy", [False, True])
def test_local_backend_cannot_enable_alternate_agent_authority(legacy):
    selected = local_profile()
    if legacy:
        selected["agent_connection"]["legacy_tools"] = {
            "disposition": "managed_api_key", "credential_source": "managed_environment_agent_api_key"}
    else:
        selected["agent_connection"]["byo_host"]["disposition"] = "disabled"
    with pytest.raises(DeploymentProfileError, match="agent dispositions"):
        parse_profile(selected)


@pytest.mark.parametrize("distribution", ["production", "generic_developer"])
def test_existing_distribution_boundaries_are_not_relaxed(distribution):
    selected = local_profile()
    selected["distribution"] = distribution
    with pytest.raises(DeploymentProfileError, match="local"):
        parse_profile(selected)


def test_invalid_persisted_local_selection_does_not_return_to_sandbox():
    selected = local_profile()
    selected["websocket_endpoint"] = "ws://192.168.1.2:8001/ws"
    with pytest.raises(DeploymentProfileError, match="loopback"):
        resolve_startup([], resource_root=ROOT, expected_client_version="0.5.2", frozen=True,
                        environment={}, persisted_profile_json=json.dumps(selected))


def test_local_runtime_namespace_is_stable_and_keeps_selector_separate():
    from astral_client.settings import isolate_local_settings, settings_registry_key

    selector = {}
    selected = resolve_startup([], resource_root=ROOT, expected_client_version="0.5.2", frozen=True,
                               environment=selector, persisted_profile_json=json.dumps(local_profile()))
    runtime = dict(selector)
    isolate_local_settings(selected.effective_profile.digest, runtime)
    assert selector == {}
    assert settings_registry_key(selector) == r"Software\AstralDeep\WindowsClient"
    assert settings_registry_key(runtime) != settings_registry_key(selector)
    second = {}
    isolate_local_settings(selected.effective_profile.digest, second)
    assert runtime == second
    isolate_local_settings("different-local-profile", second)
    assert runtime == second
    third = {}
    isolate_local_settings("different-local-profile", third)
    assert runtime != third


def test_explicit_runtime_namespace_is_preserved_and_invalid_namespace_refused():
    from astral_client.settings import PROFILE_ENVIRONMENT_KEY, SettingsProfileError, isolate_local_settings

    environment = {PROFILE_ENVIRONMENT_KEY: "11111111-1111-4111-8111-111111111111"}
    isolate_local_settings("local-profile", environment)
    assert environment[PROFILE_ENVIRONMENT_KEY] == "11111111-1111-4111-8111-111111111111"
    with pytest.raises(SettingsProfileError):
        isolate_local_settings("local-profile", {PROFILE_ENVIRONMENT_KEY: "invalid"})


def test_entrypoint_isolates_local_state_before_gui_reads_settings(monkeypatch):
    import main as entrypoint
    from astral_client import app, settings

    monkeypatch.delenv(settings.PROFILE_ENVIRONMENT_KEY, raising=False)
    observed = []

    def start_gui(*, effective_profile, argv):
        observed.append(settings.settings_registry_key())
        assert effective_profile.profile.websocket_endpoint == "ws://127.0.0.1:8001/ws"
        assert argv == []
        return 0

    monkeypatch.setattr(app, "main", start_gui)
    assert entrypoint.main(["--deployment-profile", str(PROFILE)]) == 0
    assert len(observed) == 1
    assert observed[0] != settings.settings_registry_key({})
    assert observed[0].startswith(r"Software\AstralDeep\WindowsClientProfile-")


def test_local_window_identifies_target_without_starting_transport(monkeypatch, native_root):
    from astral_client.app import MainWindow

    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    profile = resolve_startup(
        ["--deployment-profile", str(PROFILE)], resource_root=ROOT,
        expected_client_version="0.5.2", frozen=True, environment={},
    ).effective_profile
    window = native_root(MainWindow, profile.profile.websocket_endpoint, "", connect=False,
                         deployment_profile=profile)
    assert window.windowTitle() == "AstralDeep — Windows — Local testing"
    assert window.client.url == profile.profile.websocket_endpoint
    assert window._byo.deployment_profile_digest == profile.digest
