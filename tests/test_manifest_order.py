"""Checks deterministic vocabulary ordering in the authoritative protocol manifest."""

import pytest

from astralprojection.protocol import read_protocol_manifest


@pytest.mark.parametrize("field", ["push_types", "accept_actions", "component_types"])
def test_manifest_vocabularies_are_unique_and_sorted(field):
    values = read_protocol_manifest()[field]
    names = [value["name"] for value in values] if field == "push_types" else values
    assert len(names) == len(set(names))
    assert names == sorted(names)
