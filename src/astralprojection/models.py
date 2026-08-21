"""Host-neutral presentation records for AstralProjection.

These records deliberately contain no AstralDeep implementation types.  A host
authorizes and queries state, translates it into plain values, and then passes
those values to Projection's pure view builders.  Every record is immutable and
serializes to JSON-compatible values so it can be used by web and native hosts.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field, replace
from types import MappingProxyType
from typing import TypeAlias

JsonScalar: TypeAlias = None | bool | int | float | str
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]

_TOKEN_RE = re.compile(r"^[a-z][a-z0-9_.:-]*$")
_HEX_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
_LAYOUT_MODES = frozenset({"compact", "standard", "wide", "watch"})
_DENSITIES = frozenset({"compact", "comfortable"})
_COLOR_SCHEMES = frozenset({"dark", "light"})
_CONTRASTS = frozenset({"normal", "high"})
_FALLBACKS = frozenset({"alert", "text"})


def _token(value: str, label: str) -> str:
    normalized = str(value or "").strip().lower()
    if not _TOKEN_RE.fullmatch(normalized):
        raise ValueError(f"{label} must be a lowercase protocol token")
    return normalized


def _freeze_json(value: object, path: str = "value") -> object:
    """Validate and freeze a JSON-compatible value without string coercion."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError(f"{path} contains a non-finite number")
        return value
    if isinstance(value, Mapping):
        frozen: dict[str, object] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise TypeError(f"{path} contains a non-string key")
            frozen[key] = _freeze_json(item, f"{path}.{key}")
        return MappingProxyType(frozen)
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return tuple(_freeze_json(item, f"{path}[]") for item in value)
    raise TypeError(f"{path} contains unsupported value type {type(value).__name__}")


def thaw_json(value: object) -> JsonValue:
    """Return a detached JSON-compatible copy of a frozen presentation value."""
    if isinstance(value, Mapping):
        return {str(key): thaw_json(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [thaw_json(item) for item in value]
    return value  # type: ignore[return-value]


@dataclass(frozen=True, slots=True)
class ComponentView:
    """One protocol-neutral UI component dictionary."""

    component_type: str
    properties: Mapping[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        object.__setattr__(self, "component_type", _token(self.component_type, "component_type"))
        if "type" in self.properties:
            raise ValueError("component properties must not override type")
        object.__setattr__(self, "properties", _freeze_json(self.properties, "properties"))

    def to_dict(self) -> dict[str, JsonValue]:
        return {"type": self.component_type, **thaw_json(self.properties)}


@dataclass(frozen=True, slots=True)
class FrameView:
    """A transport-neutral frame payload for a host to wrap and deliver."""

    frame_type: str
    payload: Mapping[str, object]
    schema_version: int = 1

    def __post_init__(self) -> None:
        object.__setattr__(self, "frame_type", _token(self.frame_type, "frame_type"))
        if self.schema_version < 1:
            raise ValueError("schema_version must be positive")
        if "type" in self.payload or "schema_version" in self.payload:
            raise ValueError("frame payload must not override envelope fields")
        object.__setattr__(self, "payload", _freeze_json(self.payload, "payload"))

    def to_dict(self) -> dict[str, JsonValue]:
        return {
            "type": self.frame_type,
            "schema_version": self.schema_version,
            **thaw_json(self.payload),
        }


@dataclass(frozen=True, slots=True)
class ThemeView:
    """Resolved semantic theme supplied to a presentation surface."""

    name: str = "midnight"
    colors: Mapping[str, str] = field(default_factory=dict)
    color_scheme: str = "dark"
    contrast: str = "normal"

    def __post_init__(self) -> None:
        name = _token(self.name, "theme name")
        scheme = str(self.color_scheme).strip().lower()
        contrast = str(self.contrast).strip().lower()
        if scheme not in _COLOR_SCHEMES:
            raise ValueError("color_scheme must be dark or light")
        if contrast not in _CONTRASTS:
            raise ValueError("contrast must be normal or high")
        colors: dict[str, str] = {}
        for raw_key, raw_value in self.colors.items():
            key = _token(raw_key, "theme color key")
            value = str(raw_value).strip()
            if not _HEX_COLOR_RE.fullmatch(value):
                raise ValueError(f"theme color {key} must be #RRGGBB")
            colors[key] = value.lower()
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "color_scheme", scheme)
        object.__setattr__(self, "contrast", contrast)
        object.__setattr__(self, "colors", MappingProxyType(colors))

    def to_dict(self) -> dict[str, JsonValue]:
        return {
            "name": self.name,
            "colors": dict(self.colors),
            "color_scheme": self.color_scheme,
            "contrast": self.contrast,
        }


@dataclass(frozen=True, slots=True)
class LayoutView:
    """Shared layout intent, bounded for every supported client."""

    mode: str = "standard"
    columns: int = 1
    density: str = "comfortable"
    areas: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        mode = str(self.mode).strip().lower()
        density = str(self.density).strip().lower()
        if mode not in _LAYOUT_MODES:
            raise ValueError(f"unsupported layout mode: {mode}")
        if density not in _DENSITIES:
            raise ValueError(f"unsupported layout density: {density}")
        if not 1 <= self.columns <= 4:
            raise ValueError("columns must be between 1 and 4")
        areas = tuple(_token(area, "layout area") for area in self.areas)
        if len(set(areas)) != len(areas):
            raise ValueError("layout areas must be unique")
        object.__setattr__(self, "mode", mode)
        object.__setattr__(self, "density", density)
        object.__setattr__(self, "areas", areas)

    def to_dict(self) -> dict[str, JsonValue]:
        return {
            "mode": self.mode,
            "columns": self.columns,
            "density": self.density,
            "areas": list(self.areas),
        }


@dataclass(frozen=True, slots=True)
class DegradationView:
    """Explicit, user-visible record of a supported presentation fallback."""

    active: bool = False
    reason: str = ""
    unsupported_components: tuple[str, ...] = ()
    fallback: str = "alert"

    def __post_init__(self) -> None:
        unsupported = tuple(
            sorted({_token(item, "unsupported component") for item in self.unsupported_components})
        )
        fallback = str(self.fallback).strip().lower()
        if fallback not in _FALLBACKS:
            raise ValueError("fallback must be alert or text")
        reason = str(self.reason or "").strip()
        if self.active and not reason:
            raise ValueError("active degradation requires a visible reason")
        object.__setattr__(self, "unsupported_components", unsupported)
        object.__setattr__(self, "fallback", fallback)
        object.__setattr__(self, "reason", reason)

    def to_dict(self) -> dict[str, JsonValue]:
        return {
            "active": self.active,
            "reason": self.reason,
            "unsupported_components": list(self.unsupported_components),
            "fallback": self.fallback,
        }


@dataclass(frozen=True, slots=True)
class DeviceCapabilities:
    """Presentation capabilities advertised by a web or native client."""

    profile: str
    component_types: frozenset[str]
    supports_forms: bool = True
    supports_html: bool = True
    supports_local_actions: bool = True
    max_columns: int = 4

    def __post_init__(self) -> None:
        object.__setattr__(self, "profile", _token(self.profile, "device profile"))
        object.__setattr__(
            self,
            "component_types",
            frozenset(_token(item, "component type") for item in self.component_types),
        )
        if not 1 <= self.max_columns <= 4:
            raise ValueError("max_columns must be between 1 and 4")

    def supports(self, component_type: str) -> bool:
        component = _token(component_type, "component type")
        if component == "param_picker" and not self.supports_forms:
            return False
        return component in self.component_types

    def to_dict(self) -> dict[str, JsonValue]:
        return {
            "profile": self.profile,
            "component_types": sorted(self.component_types),
            "supports_forms": self.supports_forms,
            "supports_html": self.supports_html,
            "supports_local_actions": self.supports_local_actions,
            "max_columns": self.max_columns,
        }


@dataclass(frozen=True, slots=True)
class ChromeViewModel:
    """Complete pure output for one shared application-chrome surface."""

    surface: str
    title: str
    components: tuple[ComponentView, ...]
    theme: ThemeView = field(default_factory=ThemeView)
    layout: LayoutView = field(default_factory=LayoutView)
    degradation: DegradationView = field(default_factory=DegradationView)

    def __post_init__(self) -> None:
        object.__setattr__(self, "surface", _token(self.surface, "surface"))
        title = str(self.title or "").strip()
        if not title:
            raise ValueError("title must not be empty")
        if not all(isinstance(item, ComponentView) for item in self.components):
            raise TypeError("components must contain ComponentView records")
        object.__setattr__(self, "title", title)
        object.__setattr__(self, "components", tuple(self.components))

    def to_dict(self) -> dict[str, JsonValue]:
        return {
            "surface": self.surface,
            "title": self.title,
            "components": [component.to_dict() for component in self.components],
            "theme": self.theme.to_dict(),
            "layout": self.layout.to_dict(),
            "degradation": self.degradation.to_dict(),
        }

    def to_frame(self) -> FrameView:
        return FrameView("chrome_surface", self.to_dict())

    def for_device(self, capabilities: DeviceCapabilities) -> ChromeViewModel:
        """Replace unsupported top-level components with an explicit fallback."""
        supported: list[ComponentView] = []
        unsupported: set[str] = set()
        for component in self.components:
            if capabilities.supports(component.component_type):
                supported.append(component)
            else:
                unsupported.add(component.component_type)
                supported.append(
                    ComponentView(
                        "alert",
                        {
                            "variant": "info",
                            "title": "Limited presentation",
                            "message": (
                                f"This {capabilities.profile} client cannot display the "
                                f"{component.component_type} control. Use another supported "
                                "client to complete this action."
                            ),
                        },
                    )
                )
        if not unsupported and self.layout.columns <= capabilities.max_columns:
            return self
        reason = "Presentation adapted to the device's declared capabilities."
        degradation = DegradationView(True, reason, tuple(unsupported), "alert")
        layout = replace(self.layout, columns=min(self.layout.columns, capabilities.max_columns))
        return replace(
            self,
            components=tuple(supported),
            layout=layout,
            degradation=degradation,
        )
