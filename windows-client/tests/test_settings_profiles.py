"""Verifies native settings isolation across startup, GUI consumers and packaged qualification.
Registry and default-profile probes use synthetic stores so tests cannot inspect user settings.
"""

from __future__ import annotations

from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from uuid import uuid4

import pytest

from astral_client import deployment, settings


PROFILE_ID = "d1290795-5488-4ba2-9a83-e6a39438cc60"
PROFILE_ENVIRONMENT = {settings.PROFILE_ENVIRONMENT_KEY: PROFILE_ID}
PROFILE_KEY = rf"Software\AstralDeep\WindowsClientProfile-{PROFILE_ID}"
CLIENT_ROOT = Path(__file__).resolve().parents[1]


def test_default_namespace_stays_compatible():
    assert settings.settings_application({}) == "WindowsClient"
    assert settings.settings_registry_key({}) == r"Software\AstralDeep\WindowsClient"


def test_explicit_namespace_is_stable_and_separate(monkeypatch):
    monkeypatch.setenv(settings.PROFILE_ENVIRONMENT_KEY, PROFILE_ID)
    assert settings.settings_application() == f"WindowsClientProfile-{PROFILE_ID}"
    assert settings.settings_registry_key() == PROFILE_KEY
    assert settings.settings_registry_key(PROFILE_ENVIRONMENT) == PROFILE_KEY
    other = {settings.PROFILE_ENVIRONMENT_KEY: str(uuid4())}
    assert settings.settings_registry_key(other) != PROFILE_KEY


@pytest.mark.parametrize("identifier", [
    "", " ", "WindowsClient", "../WindowsClient", "a/b", "a\\b", "{{{0}}}".format(PROFILE_ID),
    PROFILE_ID.upper(), PROFILE_ID.replace("-", ""), f" {PROFILE_ID}", f"{PROFILE_ID}\n",
    "00000000-0000-0000-0000-000000000000", "d1290795-5488-1ba2-9a83-e6a39438cc60",
    None, 123,
])
def test_invalid_namespace_fails_closed(identifier):
    with pytest.raises(settings.SettingsProfileError, match="canonical UUID4"):
        settings.settings_application({settings.PROFILE_ENVIRONMENT_KEY: identifier})


@pytest.mark.parametrize("environment,application,fallbacks", [
    ({}, "WindowsClient", []),
    (PROFILE_ENVIRONMENT, f"WindowsClientProfile-{PROFILE_ID}", [False]),
])
def test_qsettings_factory_only_disables_fallbacks_for_explicit_profile(
    monkeypatch, environment, application, fallbacks,
):
    from PySide6 import QtCore

    calls = []
    fallback_calls = []
    store = SimpleNamespace(setFallbacksEnabled=fallback_calls.append)
    monkeypatch.setattr(QtCore, "QSettings", lambda *args: calls.append(args) or store)
    assert settings.create_settings(environment) is store
    assert calls == [("AstralDeep", application)]
    assert fallback_calls == fallbacks


def test_invalid_factory_profile_never_opens_store(monkeypatch):
    from PySide6 import QtCore

    def reject_open(*args):
        pytest.fail("invalid profile opened settings")

    monkeypatch.setattr(QtCore, "QSettings", reject_open)
    with pytest.raises(settings.SettingsProfileError):
        settings.create_settings({settings.PROFILE_ENVIRONMENT_KEY: "WindowsClient"})


@pytest.mark.skipif(sys.platform != "win32", reason="verifies Qt native registry interoperability")
def test_selected_qsettings_profile_and_startup_share_native_storage():
    from PySide6.QtCore import QSettings

    first_environment = {settings.PROFILE_ENVIRONMENT_KEY: str(uuid4())}
    second_environment = {settings.PROFILE_ENVIRONMENT_KEY: str(uuid4())}
    first = settings.create_settings(first_environment)
    second = settings.create_settings(second_environment)
    value = '{"profile":"synthetic-isolated-profile"}'
    assert first.fallbacksEnabled() is False
    assert second.fallbacksEnabled() is False
    assert first.fileName() != second.fileName()
    first.setValue("deployment/profile_json", value)
    first.sync()
    assert first.status() == QSettings.Status.NoError
    assert deployment.read_persisted_profile(first_environment) == value
    assert deployment.read_persisted_profile(second_environment) is None
    assert second.value("deployment/profile_json") is None


@pytest.fixture
def registry(monkeypatch):
    probes = []
    values = {}

    @contextmanager
    def open_key(root, path):
        assert root == "current-user"
        probes.append(path)
        value = values.get(path)
        if isinstance(value, Exception):
            raise value
        if value is None:
            raise FileNotFoundError
        yield value

    module = SimpleNamespace(
        HKEY_CURRENT_USER="current-user", REG_SZ=1, REG_EXPAND_SZ=2,
        OpenKey=open_key, QueryValueEx=lambda key, name: key[name],
    )
    monkeypatch.setitem(sys.modules, "winreg", module)
    monkeypatch.setattr(deployment, "os", SimpleNamespace(name="nt", environ={}))
    return SimpleNamespace(probes=probes, values=values)


@pytest.mark.parametrize("suffix,value_name", [
    (r"\deployment", "profile_json"), ("", "deployment/profile_json"),
])
def test_persisted_deployment_reads_only_selected_profile(registry, suffix, value_name):
    registry.values[PROFILE_KEY + suffix] = {value_name: ('{"profile":"isolated"}', 1)}
    registry.values[r"Software\AstralDeep\WindowsClient\deployment"] = {
        "profile_json": ('{"profile":"private-user-profile"}', 1),
    }
    assert deployment.read_persisted_profile(PROFILE_ENVIRONMENT) == '{"profile":"isolated"}'
    assert registry.probes
    assert all(path.startswith(PROFILE_KEY) for path in registry.probes)


def test_missing_profile_does_not_fall_back_to_user_registry(registry):
    registry.values[r"Software\AstralDeep\WindowsClient\deployment"] = {
        "profile_json": ('{"profile":"private-user-profile"}', 1),
    }
    assert deployment.read_persisted_profile(PROFILE_ENVIRONMENT) is None
    assert registry.probes == [PROFILE_KEY + r"\deployment", PROFILE_KEY]


def test_default_persisted_deployment_path_is_unchanged(registry):
    registry.values[r"Software\AstralDeep\WindowsClient\deployment"] = {
        "profile_json": ('{"profile":"synthetic-default"}', 2),
    }
    assert deployment.read_persisted_profile({}) == '{"profile":"synthetic-default"}'


@pytest.mark.parametrize("value", [(b"bad", 1), ("bad", 99)])
def test_bad_persisted_registry_type_fails_closed(registry, value):
    registry.values[PROFILE_KEY + r"\deployment"] = {"profile_json": value}
    with pytest.raises(deployment.DeploymentProfileError, match="invalid registry type"):
        deployment.read_persisted_profile(PROFILE_ENVIRONMENT)


def test_unreadable_registry_fails_without_default_profile(registry):
    registry.values[PROFILE_KEY + r"\deployment"] = PermissionError("denied")
    with pytest.raises(deployment.DeploymentProfileError, match="unreadable"):
        deployment.read_persisted_profile(PROFILE_ENVIRONMENT)
    assert registry.probes == [PROFILE_KEY + r"\deployment"]


def test_invalid_profile_rejected_before_registry_access(registry):
    with pytest.raises(deployment.DeploymentProfileError, match="canonical UUID4"):
        deployment.read_persisted_profile({settings.PROFILE_ENVIRONMENT_KEY: "bad"})
    assert registry.probes == []


def test_non_windows_persisted_profile_does_not_use_registry(monkeypatch):
    monkeypatch.setattr(deployment, "os", SimpleNamespace(name="posix"))
    assert deployment.read_persisted_profile(PROFILE_ENVIRONMENT) is None


def test_startup_passes_explicit_environment_to_registry(registry):
    resolved = deployment.resolve_startup(
        [], resource_root=CLIENT_ROOT, expected_client_version="0.6.0",
        frozen=True, environment=PROFILE_ENVIRONMENT,
    )
    assert resolved.effective_profile.source == "bundled_release"
    assert registry.probes == [PROFILE_KEY + r"\deployment", PROFILE_KEY]


def test_invalid_profile_rejected_even_with_managed_deployment(registry):
    with pytest.raises(deployment.DeploymentProfileError, match="canonical UUID4"):
        deployment.resolve_startup(
            [], resource_root=CLIENT_ROOT, expected_client_version="0.6.0", frozen=True,
            environment={settings.PROFILE_ENVIRONMENT_KEY: "bad",
                         "ASTRAL_MANAGED_DEPLOYMENT_PROFILE": "unused.json"},
        )
    assert registry.probes == []


def test_native_consumers_use_injected_settings_factory(monkeypatch):
    from astral_client import protocol, remote_control

    values = {}
    store = SimpleNamespace(value=lambda key, default=None, **kwargs: values.get(key, default),
                            setValue=values.__setitem__, sync=lambda: None)
    monkeypatch.setattr(protocol, "create_settings", lambda: store)
    monkeypatch.setattr(remote_control, "create_settings", lambda: store)
    assert protocol.ConversationResumeStore().settings is store
    device_id = protocol.load_or_create_voice_device_id()
    assert values[protocol.VOICE_DEVICE_ID_KEY] == device_id
    assert protocol.load_or_create_voice_device_id() == device_id
    remote = remote_control.RemoteControlSettings()
    remote.enabled = True
    assert values[remote_control.ENABLED_KEY] is True


@pytest.mark.parametrize("module_name", ["test_packaged_release", "release_evidence_060"])
def test_packaged_environment_never_reuses_inherited_profile(tmp_path, monkeypatch, module_name):
    monkeypatch.setenv("ASTRAL_WINDOWS_EXE", str(tmp_path / "unused.exe"))
    monkeypatch.setenv(settings.PROFILE_ENVIRONMENT_KEY, PROFILE_ID)
    monkeypatch.setenv("ASTRAL_TOKEN", "synthetic-inherited-token")
    spec = importlib.util.spec_from_file_location(
        module_name, CLIENT_ROOT / "tests" / f"{module_name}.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    first_root = tmp_path / "first"
    second_root = tmp_path / "second"
    first_root.mkdir()
    second_root.mkdir()
    first = module._clean_env(first_root)
    second = module._clean_env(second_root)
    first_key = settings.settings_registry_key(first)
    second_key = settings.settings_registry_key(second)
    assert len({first_key, second_key, PROFILE_KEY}) == 3
    assert "ASTRAL_TOKEN" not in first
    assert "ASTRAL_TOKEN" not in second
    assert Path(first["APPDATA"]).is_relative_to(first_root)
    assert Path(second["LOCALAPPDATA"]).is_relative_to(second_root)


def test_profile_resolution_imports_no_qt():
    script = (
        "import sys; from astral_client import deployment, settings; "
        f"assert settings.settings_registry_key({json.dumps(PROFILE_ENVIRONMENT)}) "
        f"== {PROFILE_KEY!r}; "
        "assert not any(name.startswith('PySide6') for name in sys.modules)"
    )
    result = subprocess.run([sys.executable, "-c", script], cwd=CLIENT_ROOT,
                            capture_output=True, text=True, check=False, timeout=15)
    assert result.returncode == 0, result.stderr
