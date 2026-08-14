"""Strictly load and materialize the shared Feature 065 fixture.

This module is deliberately stdlib-only and independent of AstralDeep's
contract-validation toolchain. It implements only the fixture operations that
native client conformance tests need; schema and OpenAPI validation remain a
separate contract-CI responsibility.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any, Mapping

MAX_FIXTURE_BYTES = 2 * 1024 * 1024


class VoiceFixtureError(ValueError):
    """Raised when a shared voice fixture cannot be loaded or materialized."""


def _reject_duplicate_pairs(pairs: list[tuple[Any, Any]]) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key, value in pairs:
        if key in result:
            raise VoiceFixtureError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def _reject_nonfinite(value: str) -> None:
    raise VoiceFixtureError(f"non-finite JSON number is forbidden: {value}")


def strict_load_json(path: Path) -> dict[str, Any]:
    """Load one bounded UTF-8 JSON object with strict key/number handling."""

    try:
        size = path.stat().st_size
    except OSError as exc:
        raise VoiceFixtureError(f"cannot stat fixture {path}: {exc}") from exc
    if size > MAX_FIXTURE_BYTES:
        raise VoiceFixtureError(f"fixture exceeds {MAX_FIXTURE_BYTES} bytes: {path}")
    try:
        source = path.read_text(encoding="utf-8")
        loaded = json.loads(
            source,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError) as exc:
        raise VoiceFixtureError(f"invalid fixture {path}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise VoiceFixtureError(f"fixture must be one JSON object: {path}")
    return loaded


def _merge_vector(base: dict[str, Any], child: Mapping[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(base)
    for key, value in child.items():
        if key in {"base_vector", "mutations"}:
            continue
        if key == "context" and isinstance(result.get(key), dict) and isinstance(value, dict):
            merged = copy.deepcopy(result[key])
            merged.update(copy.deepcopy(value))
            result[key] = merged
        else:
            result[key] = copy.deepcopy(value)
    return result


def _pointer_parent(document: Any, path: str) -> tuple[Any, str]:
    if not path.startswith("/") or path == "/":
        raise VoiceFixtureError(f"invalid fixture mutation path: {path!r}")
    tokens = [token.replace("~1", "/").replace("~0", "~") for token in path[1:].split("/")]
    current = document
    for token in tokens[:-1]:
        try:
            current = current[int(token)] if isinstance(current, list) else current[token]
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise VoiceFixtureError(f"fixture mutation path does not exist: {path}") from exc
    return current, tokens[-1]


def _apply_mutation(target: Any, mutation: Mapping[str, Any]) -> None:
    operation = mutation.get("op")
    path = mutation.get("path")
    if not isinstance(path, str):
        raise VoiceFixtureError("fixture mutation path must be a string")
    parent, token = _pointer_parent(target, path)

    def present() -> bool:
        if isinstance(parent, list):
            try:
                index = int(token)
            except ValueError:
                return False
            return 0 <= index < len(parent)
        return isinstance(parent, dict) and token in parent

    if operation == "remove":
        if not present():
            raise VoiceFixtureError(f"cannot remove absent fixture path: {path}")
        if isinstance(parent, list):
            del parent[int(token)]
        else:
            del parent[token]
        return
    if operation not in {"add", "replace", "repeat"}:
        raise VoiceFixtureError(f"unsupported fixture mutation operation: {operation!r}")
    if operation in {"replace", "repeat"} and not present():
        raise VoiceFixtureError(f"cannot replace absent fixture path: {path}")
    if operation == "repeat":
        value = mutation.get("value")
        count = mutation.get("count")
        if not isinstance(value, str) or not isinstance(count, int) or count < 0:
            raise VoiceFixtureError("repeat mutation requires a string and non-negative count")
        replacement: Any = value * count
    else:
        replacement = copy.deepcopy(mutation.get("value"))
    if isinstance(parent, list):
        index = int(token)
        if operation == "add" and index == len(parent):
            parent.append(replacement)
        else:
            parent[index] = replacement
    else:
        parent[token] = replacement


def index_fixture_vectors(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Index every non-aggregate fixture vector and reject duplicate IDs."""

    cases = document.get("cases", [])
    if not isinstance(cases, list):
        raise VoiceFixtureError("fixture cases must be an array")
    groups: list[Any] = []
    for case in cases:
        if not isinstance(case, dict):
            raise VoiceFixtureError("every fixture case must be an object")
        groups.extend([case.get("positive", []), case.get("negative", [])])
    for section_name in ("worker_control_vectors", "openapi_instances"):
        section = document.get(section_name, {})
        if not isinstance(section, dict):
            raise VoiceFixtureError(f"fixture {section_name} must be an object")
        groups.extend([section.get("positive", []), section.get("negative", [])])
    proofs = document.get("proof_vectors", {})
    if not isinstance(proofs, dict):
        raise VoiceFixtureError("fixture proof_vectors must be an object")
    groups.extend([proofs.get("golden", []), proofs.get("negative", [])])

    indexed: dict[str, dict[str, Any]] = {}
    for group in groups:
        if not isinstance(group, list):
            raise VoiceFixtureError("fixture vector groups must be arrays")
        for vector in group:
            if not isinstance(vector, dict) or not isinstance(vector.get("id"), str):
                raise VoiceFixtureError("every fixture vector requires a string id")
            vector_id = vector["id"]
            if vector_id in indexed:
                raise VoiceFixtureError(f"duplicate fixture vector id: {vector_id}")
            indexed[vector_id] = vector
    return indexed


def materialize_vector(
    vector: Mapping[str, Any],
    document: dict[str, Any],
    indexed: Mapping[str, dict[str, Any]],
    *,
    _stack: tuple[str, ...] = (),
) -> dict[str, Any]:
    """Expand one base/mutation vector without mutating the shared fixture."""

    vector_id = vector.get("id")
    if not isinstance(vector_id, str):
        raise VoiceFixtureError("fixture vector has no string id")
    if vector_id in _stack:
        raise VoiceFixtureError(f"fixture vector inheritance cycle at {vector_id}")
    base_id = vector.get("base_vector")
    if base_id is not None:
        if not isinstance(base_id, str) or base_id not in indexed:
            raise VoiceFixtureError(f"unknown base fixture vector for {vector_id}")
        base = materialize_vector(
            indexed[base_id],
            document,
            indexed,
            _stack=(*_stack, vector_id),
        )
        result = _merge_vector(base, vector)
    else:
        result = copy.deepcopy(dict(vector))

    payload_base = result.get("payload_base")
    if payload_base is not None:
        bases = document.get("payload_bases", {})
        if (
            not isinstance(bases, dict)
            or not isinstance(payload_base, str)
            or payload_base not in bases
        ):
            raise VoiceFixtureError(f"unknown payload base for {vector_id}")
        base_payload = copy.deepcopy(bases[payload_base])
        payload = result.get("payload", {})
        if not isinstance(base_payload, dict) or not isinstance(payload, dict):
            raise VoiceFixtureError(f"invalid payload base for {vector_id}")
        base_payload.update(copy.deepcopy(payload))
        result["payload"] = base_payload
        result.pop("payload_base", None)

    target = result.get("payload") if ("contract" in result or "schema" in result) else result
    mutations = vector.get("mutations", [])
    if not isinstance(mutations, list):
        raise VoiceFixtureError(f"invalid mutations in {vector_id}")
    for mutation in mutations:
        if not isinstance(mutation, dict):
            raise VoiceFixtureError(f"invalid mutation in {vector_id}")
        _apply_mutation(target, mutation)
    result.pop("mutations", None)
    result.pop("base_vector", None)
    return result
