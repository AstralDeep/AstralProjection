"""Per-session device-profile registry and adaptation entry point: registers/updates
each WebSocket's DeviceProfile from register_ui, caches raw components for
viewport-change re-adaptation, and calls ComponentAdapter.adapt before
send_ui_render.
"""

import copy
import logging
from typing import Any, Dict, List, Optional, Tuple

from rote.capabilities import DeviceProfile, DeviceType
from rote.adapter import ComponentAdapter

logger = logging.getLogger("ROTE")


class ROTE:
    def __init__(self):
        self._profiles: Dict[Any, DeviceProfile] = {}
        self._last_components: Dict[Any, List[Dict]] = {}

    def register_device(self, websocket: Any, device_info: Dict[str, Any]) -> DeviceProfile:
        profile = DeviceProfile.from_dict(device_info) if device_info else DeviceProfile.default()
        self._profiles[websocket] = profile
        logger.info(
            f"ROTE: registered device — type={profile.device_type.value} "
            f"viewport={profile.capabilities.viewport_width}x{profile.capabilities.viewport_height} "
            f"charts={profile.supports_charts} tables={profile.supports_tables} "
            f"grid_cols={profile.max_grid_columns}"
        )
        return profile

    def update_device(
        self, websocket: Any, device_info: Dict[str, Any]
    ) -> Tuple[DeviceProfile, Optional[List[Dict]], bool]:
        old_profile = self._profiles.get(websocket)
        new_profile = DeviceProfile.from_dict(device_info) if device_info else DeviceProfile.default()
        self._profiles[websocket] = new_profile

        changed = (
            old_profile is None
            or old_profile.device_type != new_profile.device_type
            or old_profile.max_grid_columns != new_profile.max_grid_columns
            or old_profile.capabilities.viewport_width != new_profile.capabilities.viewport_width
            or old_profile.capabilities.viewport_height != new_profile.capabilities.viewport_height
        )

        logger.info(
            f"ROTE: device update — type={new_profile.device_type.value} "
            f"viewport={new_profile.capabilities.viewport_width}x{new_profile.capabilities.viewport_height} "
            f"changed={changed}"
        )

        if not changed:
            return new_profile, None, False

        raw = self._last_components.get(websocket)
        if not raw:
            return new_profile, None, True

        if new_profile.device_type == DeviceType.BROWSER:
            return new_profile, raw, True

        adapted = ComponentAdapter.adapt(raw, new_profile)
        logger.debug(
            f"ROTE: re-adapted {len(raw)} → {len(adapted)} components "
            f"after viewport change for {new_profile.device_type.value}"
        )
        return new_profile, adapted, True

    def cleanup(self, websocket: Any) -> None:
        self._profiles.pop(websocket, None)
        self._last_components.pop(websocket, None)

    def get_profile(self, websocket: Any) -> DeviceProfile:
        return self._profiles.get(websocket, DeviceProfile.default())

    def get_cached_components(self, websocket: Any) -> Optional[List[Dict]]:
        return copy.deepcopy(self._last_components.get(websocket))

    def adapt(self, websocket: Any, components: List[Dict]) -> List[Dict]:
        self._last_components[websocket] = components

        profile = self.get_profile(websocket)

        if profile.device_type == DeviceType.BROWSER:
            return components

        adapted = ComponentAdapter.adapt(components, profile)
        logger.debug(
            f"ROTE: adapted {len(components)} → {len(adapted)} components "
            f"for {profile.device_type.value}"
        )
        return adapted
