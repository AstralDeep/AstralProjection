"""Capability fallback ladder.

A renderer target publishes the set of primitive types it can render; ROTE then
substitutes any unsupported type down a fixed degradation ladder
(timeline→list, chart→table→text, …) so the SDUI contract degrades gracefully
on a constrained or brand-new target instead of emitting an "unsupported
component" placeholder. ``text`` is assumed universally renderable and is the
terminal of every ladder.

This module is the pure contract: the ladder and :func:`first_supported`. The
structural conversion + recursion lives in ``ComponentAdapter`` (it reuses the
existing text extraction).
"""
from __future__ import annotations

from typing import AbstractSet, Any

#: Per-primitive ordered substitution candidates (best-fidelity first). Every
#: chain bottoms out at ``text``, which is assumed always supported.
FALLBACK_LADDER = {
    "timeline": ("list", "text"),
    "bar_chart": ("table", "list", "text"),
    "line_chart": ("table", "list", "text"),
    "pie_chart": ("table", "list", "text"),
    "plotly_chart": ("table", "list", "text"),
    "table": ("list", "text"),
    "keyvalue": ("table", "list", "text"),
    "metric": ("text",),
    "hero": ("text",),
    "rating": ("text",),
    "badge": ("text",),
    "alert": ("text",),
    "list": ("text",),
    "code": ("text",),
    "grid": ("container", "list", "text"),
    "tabs": ("container", "list", "text"),
    "collapsible": ("container", "card", "text"),
    "card": ("container", "text"),
    "container": ("text",),
    "divider": ("text",),
    "image": ("text",),
    "skeleton": ("text",),
}

#: Terminal fallback — assumed renderable everywhere.
TERMINAL = "text"


def first_supported(ctype: str, supported: AbstractSet[str]) -> str:
    """The type ``ctype`` should render AS, given the target's ``supported``
    set: ``ctype`` itself when supported, else the first ladder step that is
    supported, else :data:`TERMINAL` (``text``). Pure + total."""
    c = (ctype or "").strip().lower()
    if not supported or c in supported:
        return c or TERMINAL
    for cand in FALLBACK_LADDER.get(c, (TERMINAL,)):
        if cand in supported:
            return cand
    return TERMINAL


def typed_voice_fallback(capabilities: Any, reason: str) -> dict[str, object]:
    """Return the closed client-local unavailable shape while retaining typed UI."""
    return {
        "available": False,
        "disposition": "typed_fallback",
        "reason": reason,
        "speech_backend": "client_local",
        "transport": "client_local",
        "contract": "client_local/v1",
        "configured_locale": "en-US",
        "full_duplex": False,
        "typed_fallback": True,
    }


def local_voice_disposition(capabilities: Any) -> dict[str, object]:
    """Classify normalized local speech facts into one closed ROTE disposition."""
    if capabilities.voice_transport != "client_local" or capabilities.voice_contract != (
        "client_local/v1"
    ):
        return typed_voice_fallback(capabilities, "client_contract_upgrade_required")
    if capabilities.configured_locale != "en-US" or capabilities.full_duplex:
        return typed_voice_fallback(capabilities, "client_readiness_required")
    if not capabilities.has_microphone:
        return typed_voice_fallback(capabilities, "no_microphone")
    if not capabilities.has_audio_output:
        return typed_voice_fallback(capabilities, "no_audio_output")
    if capabilities.microphone_permission in {"denied", "restricted", "unavailable"}:
        return typed_voice_fallback(capabilities, "microphone_permission_denied")
    if capabilities.microphone_permission != "authorized":
        return typed_voice_fallback(capabilities, "microphone_permission_not_determined")
    if capabilities.recognition_permission in {"denied", "restricted", "unavailable"}:
        return typed_voice_fallback(capabilities, "speech_recognition_permission_denied")
    if capabilities.recognition_permission != "authorized":
        return typed_voice_fallback(
            capabilities,
            "speech_recognition_permission_not_determined",
        )
    if capabilities.recognition_processing == "unavailable":
        return typed_voice_fallback(capabilities, "local_recognition_unavailable")
    if capabilities.recognition_processing != "guaranteed_local":
        return typed_voice_fallback(capabilities, "local_processing_not_guaranteed")
    installation_reasons = {
        "downloadable": "local_language_download_required",
        "installing": "local_language_installing",
        "failed": "local_language_install_failed",
    }
    if reason := installation_reasons.get(capabilities.recognition_installation):
        return typed_voice_fallback(capabilities, reason)
    if capabilities.recognition_installation in {"unavailable", "not_applicable"}:
        return typed_voice_fallback(capabilities, "local_recognition_unavailable")
    if capabilities.recognition_locale != "ready":
        return typed_voice_fallback(capabilities, "local_recognition_locale_unavailable")
    if capabilities.synthesis_processing == "unavailable":
        return typed_voice_fallback(capabilities, "local_synthesis_unavailable")
    if capabilities.synthesis_processing != "guaranteed_local":
        return typed_voice_fallback(capabilities, "local_processing_not_guaranteed")
    if capabilities.synthesis_locale != "ready":
        return typed_voice_fallback(capabilities, "local_synthesis_locale_unavailable")
    return {
        "available": True,
        "disposition": "ready",
        "reason": "ready",
        "speech_backend": "client_local",
        "transport": "client_local",
        "contract": "client_local/v1",
        "configured_locale": "en-US",
        "full_duplex": False,
        "typed_fallback": True,
    }
