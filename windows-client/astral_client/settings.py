"""Selects the native settings namespace shared by GUI state and deployment resolution.
Explicit profile identifiers isolate independent client runs without reading the default profile.
"""

from __future__ import annotations

import os
import hashlib
from typing import TYPE_CHECKING, Mapping, MutableMapping
from uuid import UUID

if TYPE_CHECKING:
    from PySide6.QtCore import QSettings


PROFILE_ENVIRONMENT_KEY = "ASTRAL_WINDOWS_PROFILE_ID"
SETTINGS_ORGANIZATION = "AstralDeep"
DEFAULT_APPLICATION = "WindowsClient"


class SettingsProfileError(ValueError):
    pass


def settings_application(environment: Mapping[str, str] | None = None) -> str:
    environment = os.environ if environment is None else environment
    if PROFILE_ENVIRONMENT_KEY not in environment:
        return DEFAULT_APPLICATION
    identifier = environment[PROFILE_ENVIRONMENT_KEY]
    try:
        parsed = UUID(identifier)
    except (AttributeError, TypeError, ValueError) as exc:
        raise SettingsProfileError("Windows settings profile must be a canonical UUID4") from exc
    if parsed.version != 4 or str(parsed) != identifier:
        raise SettingsProfileError("Windows settings profile must be a canonical UUID4")
    return f"WindowsClientProfile-{identifier}"


def settings_registry_key(environment: Mapping[str, str] | None = None) -> str:
    application = settings_application(environment)
    return f"Software\\{SETTINGS_ORGANIZATION}\\{application}"


def isolate_local_settings(profile_digest: str, environment: MutableMapping[str, str] | None = None) -> None:
    environment = os.environ if environment is None else environment
    settings_application(environment)
    if PROFILE_ENVIRONMENT_KEY not in environment:
        digest = hashlib.sha256(f"AstralDeep/local-backend/{profile_digest}".encode()).digest()
        environment[PROFILE_ENVIRONMENT_KEY] = str(UUID(bytes=digest[:16], version=4))


def create_settings(environment: Mapping[str, str] | None = None) -> QSettings:
    application = settings_application(environment)
    from PySide6.QtCore import QSettings

    settings = QSettings(SETTINGS_ORGANIZATION, application)
    if application != DEFAULT_APPLICATION:
        settings.setFallbacksEnabled(False)
    return settings
