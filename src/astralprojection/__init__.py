"""Stable metadata boundary (CONTRACT_VERSION) for the independent AstralProjection
package, built on protocol.py and resources.py; imported by AstralDeep's
orchestrator.py and web_auth.py.
"""

from __future__ import annotations

from .protocol import UI_PROTOCOL_SHA256, UI_PROTOCOL_VERSION, protocol_manifest_path
from .resources import (
    InvalidResourcePath,
    ResourceNotFoundError,
    contract_root,
    export_asset_path,
    fixture_path,
    font_path,
    image_path,
    notice_path,
    resource_sha256,
    static_path,
    static_root,
    template_path,
    template_root,
    vendor_path,
)

CONTRACT_VERSION = "astralprojection.contract/v1"
__version__ = "0.1.0"

__all__ = [
    "CONTRACT_VERSION",
    "UI_PROTOCOL_SHA256",
    "UI_PROTOCOL_VERSION",
    "InvalidResourcePath",
    "ResourceNotFoundError",
    "__version__",
    "contract_root",
    "export_asset_path",
    "fixture_path",
    "font_path",
    "image_path",
    "notice_path",
    "protocol_manifest_path",
    "resource_sha256",
    "static_path",
    "static_root",
    "template_path",
    "template_root",
    "vendor_path",
]
