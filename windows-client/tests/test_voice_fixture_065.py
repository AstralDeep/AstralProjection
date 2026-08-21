"""Tests for the standalone Windows voice-fixture materializer."""

from __future__ import annotations

import copy
from pathlib import Path

import pytest

from test_support.voice_fixture_065 import (
    VoiceFixtureError,
    index_fixture_vectors,
    materialize_vector,
    strict_load_json,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = REPO_ROOT / "contracts/fixtures/voice_065/client_conformance.json"


def test_canonical_projection_fixture_loads_and_materializes() -> None:
    fixture = strict_load_json(FIXTURE_PATH)
    indexed = index_fixture_vectors(fixture)

    composer = materialize_vector(indexed["C0-P1-composer"], fixture, indexed)
    mismatch = materialize_vector(indexed["C1-N1-correlation-mismatch"], fixture, indexed)

    assert composer["payload"]["type"] == "composer_state"
    assert mismatch["payload"]["type"] == "ui_event"
    assert "base_vector" not in mismatch
    assert "mutations" not in mismatch


def test_materialization_is_deep_copied_and_applies_pointer_mutations() -> None:
    fixture = {
        "payload_bases": {"base": {"nested": {"keep": True}, "items": ["first"]}},
        "cases": [
            {
                "positive": [
                    {"id": "base", "contract": "voice_control", "payload_base": "base"},
                    {
                        "id": "derived",
                        "base_vector": "base",
                        "mutations": [
                            {"op": "add", "path": "/items/1", "value": "second"},
                            {"op": "repeat", "path": "/items/0", "value": "x", "count": 3},
                            {"op": "remove", "path": "/nested/keep"},
                        ],
                    },
                ],
                "negative": [],
            }
        ],
    }
    original = copy.deepcopy(fixture)
    indexed = index_fixture_vectors(fixture)

    result = materialize_vector(indexed["derived"], fixture, indexed)

    assert result["payload"] == {"nested": {}, "items": ["xxx", "second"]}
    assert fixture == original


def test_fixture_index_rejects_duplicate_vector_ids() -> None:
    fixture = {
        "cases": [
            {
                "positive": [{"id": "duplicate"}],
                "negative": [{"id": "duplicate"}],
            }
        ]
    }

    with pytest.raises(VoiceFixtureError, match="duplicate"):
        index_fixture_vectors(fixture)


def test_materializer_rejects_unknown_bases_and_inheritance_cycles() -> None:
    unknown = {"id": "unknown", "base_vector": "missing"}
    with pytest.raises(VoiceFixtureError, match="unknown base"):
        materialize_vector(unknown, {}, {"unknown": unknown})

    left = {"id": "left", "base_vector": "right"}
    right = {"id": "right", "base_vector": "left"}
    with pytest.raises(VoiceFixtureError, match="cycle"):
        materialize_vector(left, {}, {"left": left, "right": right})


@pytest.mark.parametrize(
    "payload",
    [
        '{"duplicate": 1, "duplicate": 2}',
        '{"not_finite": NaN}',
        "[]",
    ],
)
def test_strict_loader_rejects_ambiguous_or_nonobject_json(
    tmp_path: Path,
    payload: str,
) -> None:
    fixture_path = tmp_path / "fixture.json"
    fixture_path.write_text(payload, encoding="utf-8")

    with pytest.raises(VoiceFixtureError):
        strict_load_json(fixture_path)
