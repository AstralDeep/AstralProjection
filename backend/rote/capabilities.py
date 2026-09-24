"""Device capability/profile models for ROTE: DeviceCapabilities holds what the frontend
reports in register_ui, DeviceProfile derives the rendering constraints adapter.py
enforces, with per-device-type defaults overridable via ROTE_HOST_CONFIG.
"""

import json
import logging
import os
from enum import Enum
from dataclasses import dataclass, asdict
from typing import Any, Dict, FrozenSet, Optional

logger = logging.getLogger("rote.capabilities")

_VOICE_PERMISSION_STATES = frozenset(
    {"not_determined", "authorized", "denied", "restricted", "unavailable"}
)
_VOICE_TRANSPORTS = frozenset({"livekit", "watch_pcm_websocket", "client_local"})
_LOCAL_PROCESSING_STATES = frozenset({"guaranteed_local", "unavailable", "unsupported"})
_LOCAL_LOCALE_STATES = frozenset({"ready", "unavailable", "unknown"})
_LOCAL_INSTALLATION_STATES = frozenset(
    {"ready", "downloadable", "installing", "failed", "unavailable", "not_applicable"}
)


class DeviceType(str, Enum):
    BROWSER = "browser"
    WINDOWS = "windows"
    ANDROID = "android"
    IOS = "ios"
    MACOS = "macos"
    TABLET = "tablet"
    MOBILE = "mobile"
    WATCH = "watch"
    TV = "tv"
    VOICE = "voice"


_BASE_HOST_CONFIG: Dict[str, dict] = {
    "browser": dict(max_grid_columns=6, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=True),
    "windows": dict(max_grid_columns=6, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=True),
    "android": dict(max_grid_columns=6, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=True),
    "ios":     dict(max_grid_columns=6, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=True),
    "macos":   dict(max_grid_columns=6, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=True),
    "tablet":  dict(max_grid_columns=3, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=6,
                    max_actions=0, supports_interactivity=True),
    "mobile":  dict(max_grid_columns=1, supports_charts=True, supports_tables=True,
                    supports_code=False, supports_file_io=True, supports_tabs=True,
                    max_text_chars=0, max_table_rows=20, max_table_cols=4,
                    max_actions=0, supports_interactivity=True),
    "watch":   dict(max_grid_columns=1, supports_charts=False, supports_tables=False,
                    supports_code=False, supports_file_io=False, supports_tabs=False,
                    max_text_chars=120, max_table_rows=3, max_table_cols=2,
                    max_actions=0, supports_interactivity=True),
    "tv":      dict(max_grid_columns=4, supports_charts=True, supports_tables=True,
                    supports_code=True, supports_file_io=False, supports_tabs=True,
                    max_text_chars=0, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=True),
    "voice":   dict(max_grid_columns=1, supports_charts=False, supports_tables=False,
                    supports_code=False, supports_file_io=False, supports_tabs=False,
                    max_text_chars=300, max_table_rows=0, max_table_cols=0,
                    max_actions=0, supports_interactivity=False),
}

_HOST_CONFIG_FIELDS = frozenset(_BASE_HOST_CONFIG["browser"].keys())


# Unknown or malformed env keys are ignored, never applied
def load_host_config() -> Dict[str, dict]:
    merged = {k: dict(v) for k, v in _BASE_HOST_CONFIG.items()}
    raw = os.getenv("ROTE_HOST_CONFIG")
    if not raw:
        return merged
    try:
        overrides = json.loads(raw)
        if not isinstance(overrides, dict):
            raise ValueError("ROTE_HOST_CONFIG must be a JSON object")
    except (ValueError, TypeError) as exc:
        logger.warning("ROTE_HOST_CONFIG ignored (%s); using defaults", exc)
        return merged
    for dtype, fields in overrides.items():
        if dtype not in merged or not isinstance(fields, dict):
            continue
        for key, value in fields.items():
            if key in _HOST_CONFIG_FIELDS:
                merged[dtype][key] = value
    return merged


@dataclass
class DeviceCapabilities:
    device_type: str = "browser"
    screen_width: int = 1920
    screen_height: int = 1080
    viewport_width: int = 1920
    viewport_height: int = 1080
    pixel_ratio: float = 1.0
    has_touch: bool = False
    has_geolocation: bool = False
    has_microphone: bool = False
    has_audio_output: bool = False
    microphone_permission: str = "not_determined"
    full_duplex: bool = False
    voice_transport: str = ""
    voice_contract: str = ""
    configured_locale: str = ""
    recognition_permission: str = "not_determined"
    recognition_processing: str = "unsupported"
    recognition_locale: str = "unknown"
    recognition_installation: str = "unavailable"
    synthesis_processing: str = "unsupported"
    synthesis_locale: str = "unknown"
    has_camera: bool = False
    has_file_system: bool = True
    connection_type: str = "unknown"
    user_agent: str = ""
    reduced_motion: bool = False
    pointer_type: str = "fine"


@dataclass
class DeviceProfile:
    device_type: DeviceType
    capabilities: DeviceCapabilities
    max_grid_columns: int
    supports_charts: bool
    supports_tables: bool
    supports_code: bool
    supports_file_io: bool
    supports_tabs: bool
    max_text_chars: int
    max_table_rows: int
    max_table_cols: int
    max_actions: int = 0
    supports_interactivity: bool = True
    supported_types: Optional[FrozenSet[str]] = None

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "DeviceProfile":
        valid_keys = DeviceCapabilities.__dataclass_fields__.keys()
        normalized = {k: v for k, v in data.items() if k in valid_keys}
        voice = data.get("voice")
        voice = voice if isinstance(voice, dict) else {}
        for name in (
            "has_microphone",
            "has_audio_output",
            "microphone_permission",
            "full_duplex",
            "configured_locale",
            "recognition_permission",
            "recognition_processing",
            "recognition_locale",
            "recognition_installation",
            "synthesis_processing",
            "synthesis_locale",
        ):
            if name not in normalized and name in voice:
                normalized[name] = voice[name]
        contract = normalized.get("voice_contract", voice.get("contract"))
        normalized["voice_contract"] = contract if contract == "client_local/v1" else ""

        transport = normalized.get(
            "voice_transport",
            data.get(
                "transport",
                voice.get("voice_transport", voice.get("transport")),
            ),
        )
        normalized["voice_transport"] = (
            transport if transport in _VOICE_TRANSPORTS else ""
        )
        permission = normalized.get("microphone_permission")
        normalized["microphone_permission"] = (
            permission if permission in _VOICE_PERMISSION_STATES else "not_determined"
        )
        recognition_permission = normalized.get("recognition_permission")
        normalized["recognition_permission"] = (
            recognition_permission
            if recognition_permission in _VOICE_PERMISSION_STATES
            else "not_determined"
        )
        recognition_processing = normalized.get("recognition_processing")
        normalized["recognition_processing"] = (
            recognition_processing
            if recognition_processing in _LOCAL_PROCESSING_STATES
            else "unsupported"
        )
        synthesis_processing = normalized.get("synthesis_processing")
        normalized["synthesis_processing"] = (
            synthesis_processing
            if synthesis_processing in _LOCAL_PROCESSING_STATES
            else "unsupported"
        )
        for name in ("recognition_locale", "synthesis_locale"):
            state = normalized.get(name)
            normalized[name] = state if state in _LOCAL_LOCALE_STATES else "unknown"
        installation = normalized.get("recognition_installation")
        normalized["recognition_installation"] = (
            installation if installation in _LOCAL_INSTALLATION_STATES else "unavailable"
        )
        locale = normalized.get("configured_locale")
        normalized["configured_locale"] = locale if locale == "en-US" else ""
        for name in ("has_microphone", "has_audio_output", "full_duplex"):
            value = normalized.get(name)
            normalized[name] = value if isinstance(value, bool) else False

        caps = DeviceCapabilities(**normalized)
        profile = DeviceProfile._derive(caps)
        st = data.get("supported_types")
        if isinstance(st, (list, tuple, set, frozenset)):
            cleaned = frozenset(str(t).strip().lower() for t in st if str(t).strip())
            if cleaned:
                profile.supported_types = cleaned
        return profile

    @staticmethod
    def default() -> "DeviceProfile":
        return DeviceProfile._derive(DeviceCapabilities())

    @staticmethod
    def _derive(caps: DeviceCapabilities) -> "DeviceProfile":
        raw = caps.device_type
        dt = DeviceType(raw) if raw in DeviceType._value2member_map_ else DeviceType.BROWSER

        vw = caps.viewport_width or caps.screen_width
        if dt == DeviceType.BROWSER:
            if vw <= 200:
                dt = DeviceType.WATCH
            elif vw <= 480:
                dt = DeviceType.MOBILE
            elif vw <= 1024:
                dt = DeviceType.TABLET

        host_config = load_host_config()
        fields = dict(host_config.get(dt.value, host_config[DeviceType.BROWSER.value]))
        if dt in {DeviceType.ANDROID, DeviceType.IOS, DeviceType.MACOS}:
            density_type = "mobile" if vw <= 480 else "tablet" if vw <= 1024 else "browser"
            fields["max_grid_columns"] = min(
                fields["max_grid_columns"], host_config[density_type]["max_grid_columns"]
            )
        return DeviceProfile(device_type=dt, capabilities=caps, **fields)

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["device_type"] = self.device_type.value
        if d.get("supported_types") is not None:
            d["supported_types"] = sorted(d["supported_types"])
        return d
