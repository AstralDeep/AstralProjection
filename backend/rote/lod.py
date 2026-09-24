"""Three-rung level-of-detail ladder (L1 index, L2 summary, L3 detail) and
primary-modality routing (visual/voice/text) per device, behind FF_LOD_LADDER;
resolve() is consumed by rote.adapter.ComponentAdapter's _apply_lod.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Dict, Optional


def lod_enabled() -> bool:
    return os.getenv("FF_LOD_LADDER", "false").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


L1, L2, L3 = 1, 2, 3

_FALLBACK_CHAIN: Dict[int, tuple] = {
    L3: (L3, L2, L1),
    L2: (L2, L1),
    L1: (L1,),
}

_LOD_KEY: Dict[int, str] = {L1: "l1", L2: "l2", L3: "l3"}

_PLAIN_KEYS = ("content", "text", "value")


def _device_type(device: Optional[Dict[str, Any]]) -> Optional[str]:
    if not isinstance(device, dict):
        return None
    dt = device.get("device_type")
    if isinstance(dt, str):
        dt = dt.strip().lower()
        return dt or None
    return None


def _is_small(device: Optional[Dict[str, Any]]) -> bool:
    if not isinstance(device, dict):
        return False
    return bool(device.get("is_small"))


def level_for_device(device: Optional[Dict[str, Any]]) -> int:
    dt = _device_type(device)
    if dt in ("watch", "voice"):
        return L1
    if dt == "mobile":
        return L2
    if dt in ("tablet", "browser", "tv"):
        return L3
    if dt is None and _is_small(device):
        return L2
    return L3


def _lod_dict(component: Any) -> Dict[str, Any]:
    if isinstance(component, dict):
        lod = component.get("lod")
        if isinstance(lod, dict):
            return lod
    return {}


def _plain_content(component: Any) -> str:
    if isinstance(component, dict):
        for key in _PLAIN_KEYS:
            val = component.get(key)
            if val is not None:
                return str(val)
    return ""


def _has_lod_value(lod: Dict[str, Any], level: int) -> bool:
    return lod.get(_LOD_KEY[level]) is not None


def pick_content(component: Any, device: Optional[Dict[str, Any]]) -> str:
    level = level_for_device(device)
    lod = _lod_dict(component)
    for candidate in _FALLBACK_CHAIN.get(level, (level,)):
        if _has_lod_value(lod, candidate):
            return str(lod[_LOD_KEY[candidate]])
    return _plain_content(component)


VISUAL, VOICE, TEXT = "visual", "voice", "text"


def primary_modality(device: Optional[Dict[str, Any]]) -> str:
    dt = _device_type(device)
    if dt == "voice":
        return VOICE
    if dt == "tv":
        return VISUAL
    if dt == "watch":
        return TEXT
    if dt in ("tablet", "browser"):
        return VISUAL
    if dt == "mobile":
        return TEXT if _is_small(device) else VISUAL
    return TEXT if _is_small(device) else VISUAL


@dataclass(frozen=True)
class Resolved:
    level: int
    modality: str
    content: str
    offer_detail: bool


def _deeper_lod_exists(component: Any, level: int) -> bool:
    lod = _lod_dict(component)
    return any(_has_lod_value(lod, deeper) for deeper in range(level + 1, L3 + 1))


def resolve(component: Any, device: Optional[Dict[str, Any]]) -> Resolved:
    level = level_for_device(device)
    modality = primary_modality(device)
    content = pick_content(component, device)
    offer_detail = level < L3 and _deeper_lod_exists(component, level)
    return Resolved(
        level=level,
        modality=modality,
        content=content,
        offer_detail=offer_detail,
    )
