#!/usr/bin/env python3
"""Offline verifier for the bounded Windows dual-identity bridge.

The command reads only local files.  Sigstore is explicitly placed in offline
mode, so the machine must already have a usable production trusted-root cache;
the verifier never fetches release assets and never publishes or signs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Mapping, Sequence


MAX_ARTIFACT_BYTES = 200 * 1024 * 1024
MAX_BUNDLE_BYTES = 8 * 1024 * 1024
MAX_CONTRACT_BYTES = 64 * 1024
EXPECTED_ISSUER = "https://token.actions.githubusercontent.com"
LEGACY_REPOSITORY = "AstralDeep/AstralDeep"
PROJECTION_REPOSITORY = "AstralDeep/AstralProjection"
LEGACY_WORKFLOW = (
    "https://github.com/AstralDeep/AstralDeep/.github/workflows/release-windows.yml"
)
PROJECTION_WORKFLOW = (
    "https://github.com/AstralDeep/AstralProjection/.github/workflows/release-windows.yml"
)
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\Z"
)


class BridgeVerificationError(RuntimeError):
    pass


class Version:
    __slots__ = ("major", "minor", "patch", "prerelease", "raw")

    def __init__(
        self,
        major: int,
        minor: int,
        patch: int,
        prerelease: tuple[str, ...] = (),
        raw: str = "",
    ) -> None:
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.raw = raw

    def __lt__(self, other: "Version") -> bool:
        left = (self.major, self.minor, self.patch)
        right = (other.major, other.minor, other.patch)
        if left != right:
            return left < right
        if not self.prerelease:
            return False if not other.prerelease else False
        if not other.prerelease:
            return True
        for first, second in zip(self.prerelease, other.prerelease):
            if first == second:
                continue
            first_number = first.isdigit()
            second_number = second.isdigit()
            if first_number != second_number:
                return first_number
            if first_number:
                return int(first) < int(second)
            return first < second
        return len(self.prerelease) < len(other.prerelease)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Version):
            return False
        return not self < other and not other < self


def parse_version(value: object) -> Version:
    if not isinstance(value, str) or any(item.isspace() for item in value):
        raise BridgeVerificationError("version is not strict SemVer")
    match = _SEMVER.fullmatch(value)
    if match is None:
        raise BridgeVerificationError("version is not strict SemVer")
    return Version(
        major=int(match.group(1)),
        minor=int(match.group(2)),
        patch=int(match.group(3)),
        prerelease=tuple(match.group(4).split(".")) if match.group(4) else (),
        raw=value,
    )


def _strict_json(path: Path) -> dict[str, Any]:
    try:
        if path.is_symlink() or not path.is_file():
            raise OSError
        raw = path.read_bytes()
    except OSError:
        raise BridgeVerificationError("transition contract is unreadable") from None
    if not 0 < len(raw) <= MAX_CONTRACT_BYTES:
        raise BridgeVerificationError("transition contract exceeds its size bound")

    def pairs(items: Sequence[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise ValueError
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
        raise BridgeVerificationError("transition contract is invalid JSON") from None
    if not isinstance(value, dict):
        raise BridgeVerificationError("transition contract must be an object")
    return value


def _exact(value: object, fields: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise BridgeVerificationError(f"{label} fields are not exact")
    return value


def load_contract(path: Path) -> dict[str, Any]:
    value = _exact(
        _strict_json(path),
        {
            "schemaVersion",
            "documentType",
            "client",
            "state",
            "issuer",
            "artifactName",
            "legacy",
            "projection",
            "bridge",
            "activation",
        },
        "contract",
    )
    legacy = _exact(
        value["legacy"],
        {"repository", "workflowIdentity", "tagRefTemplate", "bridgeMaximum"},
        "legacy channel",
    )
    projection = _exact(
        value["projection"],
        {"repository", "workflowIdentity", "tagRefTemplate", "minimumVersion"},
        "Projection channel",
    )
    bridge = _exact(
        value["bridge"],
        {
            "selected",
            "version",
            "artifactSha256",
            "legacyBundleSha256",
            "projectionBundleSha256",
            "legacyMaximumRule",
            "projectionMinimumRule",
            "identicalArtifactBytesRequired",
            "differentBundleBytesPermitted",
        },
        "bridge",
    )
    activation = _exact(
        value["activation"],
        {
            "releaseSelected",
            "selectionAuthority",
            "publicationAuthorized",
            "workflowsLocation",
        },
        "activation",
    )
    fixed_checks = (
        (value["schemaVersion"], 1),
        (value["documentType"], "astral.windows-release-trust-transition"),
        (value["client"], "windows"),
        (value["issuer"], EXPECTED_ISSUER),
        (value["artifactName"], "AstralDeep.exe"),
        (legacy["repository"], LEGACY_REPOSITORY),
        (legacy["workflowIdentity"], LEGACY_WORKFLOW),
        (legacy["tagRefTemplate"], "refs/tags/v<version>"),
        (projection["repository"], PROJECTION_REPOSITORY),
        (projection["workflowIdentity"], PROJECTION_WORKFLOW),
        (projection["tagRefTemplate"], "refs/tags/v<version>"),
        (bridge["legacyMaximumRule"], "equals_bridge_version"),
        (bridge["projectionMinimumRule"], "equals_bridge_version"),
        (bridge["identicalArtifactBytesRequired"], True),
        (bridge["differentBundleBytesPermitted"], True),
        (activation["selectionAuthority"], "authorized-release-planning-event"),
        (activation["publicationAuthorized"], False),
        (activation["workflowsLocation"], "workflows-disabled"),
    )
    if any(actual != expected for actual, expected in fixed_checks):
        raise BridgeVerificationError("transition trust boundary is not exact")
    state = value["state"]
    if state not in {
        "legacy_only",
        "bridge_ready",
        "dual_pinned",
        "projection_primary",
        "legacy_retired",
    }:
        raise BridgeVerificationError("transition state is unknown")
    selected = bridge["selected"] is True and activation["releaseSelected"] is True
    if state == "legacy_only":
        if selected or any(
            bridge[field] is not None
            for field in (
                "version",
                "artifactSha256",
                "legacyBundleSha256",
                "projectionBundleSha256",
            )
        ) or legacy["bridgeMaximum"] is not None or projection["minimumVersion"] is not None:
            raise BridgeVerificationError("legacy-only state contains bridge authority")
        return value
    if not selected:
        raise BridgeVerificationError("active bridge state has no selected release")
    version = bridge["version"]
    parse_version(version)
    if legacy["bridgeMaximum"] != version or projection["minimumVersion"] != version:
        raise BridgeVerificationError("bridge version bounds disagree")
    for field in ("artifactSha256", "legacyBundleSha256", "projectionBundleSha256"):
        if not isinstance(bridge[field], str) or _SHA256.fullmatch(bridge[field]) is None:
            raise BridgeVerificationError(f"{field} is not lowercase SHA-256")
    return value


def candidate_is_trusted(
    contract: Mapping[str, Any],
    *,
    repository: str,
    workflow: str,
    tag: str,
    version: str,
    artifact_sha256: str,
    current_version: str,
) -> bool:
    """Apply source, transition, and downgrade fences without network access."""

    try:
        candidate = parse_version(version)
        current = parse_version(current_version)
        state = contract["state"]
        bridge = contract["bridge"]
        bridge_version = (
            None if bridge["version"] is None else parse_version(bridge["version"])
        )
    except (BridgeVerificationError, KeyError, TypeError):
        return False
    if tag != f"v{version}" or candidate < current or candidate == current:
        return False
    legacy = repository == LEGACY_REPOSITORY and workflow == LEGACY_WORKFLOW
    projection = (
        repository == PROJECTION_REPOSITORY and workflow == PROJECTION_WORKFLOW
    )
    if not legacy and not projection:
        return False
    if state in {"legacy_only", "bridge_ready"}:
        return legacy
    if bridge_version is None:
        return False
    if legacy and (state not in {"dual_pinned", "projection_primary"} or bridge_version < candidate):
        return False
    if projection and candidate < bridge_version:
        return False
    if candidate == bridge_version:
        return artifact_sha256 == bridge["artifactSha256"]
    return state != "legacy_retired" or projection


def _sha256_file(path: Path, *, maximum: int, label: str) -> str:
    try:
        if path.is_symlink() or not path.is_file():
            raise OSError
        size = path.stat().st_size
        if not 0 < size <= maximum:
            raise OSError
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()
    except OSError:
        raise BridgeVerificationError(f"{label} is not a bounded regular file") from None


def _verify_sigstore_bundle(
    *, artifact: Path, bundle: Path, issuer: str, identity: str
) -> None:
    try:
        from sigstore.models import Bundle
        from sigstore.verify import Verifier
        from sigstore.verify.policy import Identity

        parsed = Bundle.from_json(bundle.read_bytes())
        verifier = Verifier.production(offline=True)
        verifier.verify_artifact(
            input_=artifact.read_bytes(),
            bundle=parsed,
            policy=Identity(issuer=issuer, identity=identity),
        )
    except Exception as exc:
        raise BridgeVerificationError("offline Sigstore verification failed") from exc


def verify_bridge(
    contract_path: Path,
    *,
    legacy_artifact: Path,
    projection_artifact: Path,
    legacy_bundle: Path,
    projection_bundle: Path,
) -> dict[str, Any]:
    contract = load_contract(contract_path)
    if contract["state"] not in {"dual_pinned", "projection_primary"}:
        raise BridgeVerificationError("contract is not in a dual-verifiable state")
    bridge = contract["bridge"]
    version = bridge["version"]
    artifact_digest = _sha256_file(
        legacy_artifact, maximum=MAX_ARTIFACT_BYTES, label="legacy artifact"
    )
    projection_digest = _sha256_file(
        projection_artifact, maximum=MAX_ARTIFACT_BYTES, label="Projection artifact"
    )
    if artifact_digest != projection_digest or artifact_digest != bridge["artifactSha256"]:
        raise BridgeVerificationError("bridge executable bytes are not identical")
    legacy_bundle_digest = _sha256_file(
        legacy_bundle, maximum=MAX_BUNDLE_BYTES, label="legacy bundle"
    )
    projection_bundle_digest = _sha256_file(
        projection_bundle, maximum=MAX_BUNDLE_BYTES, label="Projection bundle"
    )
    if (
        legacy_bundle_digest != bridge["legacyBundleSha256"]
        or projection_bundle_digest != bridge["projectionBundleSha256"]
    ):
        raise BridgeVerificationError("bundle digest is not decision-bound")
    tag_ref = f"refs/tags/v{version}"
    _verify_sigstore_bundle(
        artifact=legacy_artifact,
        bundle=legacy_bundle,
        issuer=contract["issuer"],
        identity=f"{contract['legacy']['workflowIdentity']}@{tag_ref}",
    )
    _verify_sigstore_bundle(
        artifact=projection_artifact,
        bundle=projection_bundle,
        issuer=contract["issuer"],
        identity=f"{contract['projection']['workflowIdentity']}@{tag_ref}",
    )
    return {
        "documentType": "astral.windows-release-bridge-verification",
        "schemaVersion": 1,
        "status": "verified",
        "version": version,
        "artifactSha256": artifact_digest,
        "legacyBundleSha256": legacy_bundle_digest,
        "projectionBundleSha256": projection_bundle_digest,
        "networkUsed": False,
        "published": False,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--legacy-artifact", type=Path, required=True)
    parser.add_argument("--projection-artifact", type=Path, required=True)
    parser.add_argument("--legacy-bundle", type=Path, required=True)
    parser.add_argument("--projection-bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    options = parser.parse_args(argv)
    try:
        result = verify_bridge(
            options.contract,
            legacy_artifact=options.legacy_artifact,
            projection_artifact=options.projection_artifact,
            legacy_bundle=options.legacy_bundle,
            projection_bundle=options.projection_bundle,
        )
    except BridgeVerificationError as exc:
        parser.error(str(exc))
    rendered = json.dumps(result, sort_keys=True, indent=2) + "\n"
    if options.output is None:
        print(rendered, end="")
    else:
        options.output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
