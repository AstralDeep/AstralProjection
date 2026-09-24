"""Validated access to AstralProjection's packaged static, template and contract
resources as Traversable objects, so callers never need to know the repository or
wheel layout.
"""

from __future__ import annotations

import hashlib
import importlib
import re
import unicodedata
from importlib import resources
from importlib.resources.abc import Traversable

_CONTRACT_RESOURCE_NAMESPACE = "astralprojection.contract-resources/v1"
_WINDOWS_DEVICE_NAMES = {
    "aux",
    "con",
    "nul",
    "prn",
    *(f"com{number}" for number in range(1, 10)),
    *(f"lpt{number}" for number in range(1, 10)),
}
_WINDOWS_FORBIDDEN = frozenset('<>:"|?*')
_WINDOWS_DRIVE = re.compile(r"^[A-Za-z]:")


class InvalidResourcePath(ValueError):
    pass


class ResourceNotFoundError(FileNotFoundError):
    pass


def _relative_parts(name: str) -> tuple[str, ...]:
    if not isinstance(name, str) or not name:
        raise InvalidResourcePath("resource name must be a non-empty string")
    if len(name) > 4096 or name != unicodedata.normalize("NFC", name):
        raise InvalidResourcePath("resource name must be bounded Unicode NFC")
    if name.startswith("/") or _WINDOWS_DRIVE.match(name) or "\\" in name:
        raise InvalidResourcePath("resource name must be a relative POSIX path")

    parts = name.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise InvalidResourcePath("resource name contains an unsafe path segment")
    for part in parts:
        stem = part.split(".", 1)[0].casefold()
        if part.casefold() == ".git" or stem in _WINDOWS_DEVICE_NAMES:
            raise InvalidResourcePath("resource name contains a reserved path segment")
        if part.endswith((" ", ".")):
            raise InvalidResourcePath("resource name contains a non-portable segment")
        if any(
            character in _WINDOWS_FORBIDDEN or ord(character) < 32 or ord(character) == 127
            for character in part
        ):
            raise InvalidResourcePath("resource name contains an unsafe character")
    return tuple(parts)


def _directory(package: str, *parts: str) -> Traversable:
    root = resources.files(package).joinpath(*parts)
    if not root.is_dir():
        joined = "/".join(parts) or "."
        raise ResourceNotFoundError(f"missing packaged directory {package}:{joined}")
    return root


def _file(root: Traversable, name: str) -> Traversable:
    candidate = root.joinpath(*_relative_parts(name))
    if not candidate.is_file():
        raise ResourceNotFoundError(f"missing packaged resource: {name}")
    return candidate


def static_root() -> Traversable:
    return _directory("webrender", "static")


def template_root() -> Traversable:
    return _directory("webrender", "templates")


def contract_root() -> Traversable:
    contract_package = importlib.import_module("contracts")
    if getattr(contract_package, "RESOURCE_NAMESPACE", None) != _CONTRACT_RESOURCE_NAMESPACE:
        raise ResourceNotFoundError("AstralProjection contract resource package is absent")
    return _directory("contracts")


def static_path(name: str) -> Traversable:
    return _file(static_root(), name)


def template_path(name: str) -> Traversable:
    return _file(template_root(), name)


def font_path(name: str) -> Traversable:
    return _file(_directory("webrender", "static", "fonts"), name)


def image_path(name: str) -> Traversable:
    return _file(_directory("webrender", "static", "img"), name)


def vendor_path(name: str) -> Traversable:
    return _file(_directory("webrender", "static", "vendor"), name)


def export_asset_path(name: str) -> Traversable:
    return _file(_directory("contracts", "assets", "exports"), name)


def protocol_manifest_path() -> Traversable:
    return _file(contract_root(), "ui_protocol.json")


def fixture_path(name: str) -> Traversable:
    return _file(_directory("contracts", "fixtures"), name)


def notice_path() -> Traversable:
    return _file(_directory("astralprojection"), "NOTICE")


def resource_sha256(resource: Traversable) -> str:
    if not resource.is_file():
        raise ResourceNotFoundError("cannot digest a missing or non-file resource")
    return hashlib.sha256(resource.read_bytes()).hexdigest()


__all__ = [
    "InvalidResourcePath",
    "ResourceNotFoundError",
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
