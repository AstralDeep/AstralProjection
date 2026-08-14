"""Stable access to AstralProjection's authoritative UI protocol manifest."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from typing import Any

from .resources import protocol_manifest_path


def _reject_nonfinite(value: str) -> None:
    raise ValueError(f"UI protocol manifest contains non-finite JSON value: {value}")


def read_protocol_manifest() -> dict[str, Any]:
    """Read a fresh validated JSON object from the authoritative manifest."""

    document = json.loads(
        protocol_manifest_path().read_text(encoding="utf-8"),
        parse_constant=_reject_nonfinite,
    )
    if not isinstance(document, dict):
        raise ValueError(  # noqa: TRY004 - stable manifest-validation API
            "UI protocol manifest must be a JSON object"
        )
    manifest_metadata(document)
    return document


def canonical_manifest_bytes(document: object) -> bytes:
    """Return whitespace- and key-order-independent UTF-8 JSON bytes."""

    return json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def manifest_metadata(document: object) -> tuple[str, str]:
    """Validate and derive the public version and canonical SHA-256."""

    if not isinstance(document, Mapping):
        raise ValueError(  # noqa: TRY004 - stable manifest-validation API
            "UI protocol manifest must be a JSON object"
        )
    version = document.get("version")
    if (
        isinstance(version, bool)
        or not isinstance(version, (int, str))
        or (isinstance(version, int) and version <= 0)
        or (isinstance(version, str) and not version.strip())
    ):
        raise ValueError("UI protocol manifest version must be a positive integer or string")
    digest = hashlib.sha256(canonical_manifest_bytes(document)).hexdigest()
    return str(version), digest


UI_PROTOCOL_VERSION, UI_PROTOCOL_SHA256 = manifest_metadata(read_protocol_manifest())


__all__ = [
    "UI_PROTOCOL_SHA256",
    "UI_PROTOCOL_VERSION",
    "canonical_manifest_bytes",
    "manifest_metadata",
    "protocol_manifest_path",
    "read_protocol_manifest",
]
