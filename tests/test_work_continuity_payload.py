"""Tests the closed Work continuity payload consumed by shared presentation, ROTE and Windows."""

from copy import deepcopy

import pytest

from astralprojection.work_continuity import validate_continuity_payload

PAYLOAD = {"version": 1, "operation_id": "180cd30b-cc38-432d-8349-1851b0d3ad7e",
           "expected_revision": 3, "submission_id": "fc5c2124-ce23-48d9-927b-9c004d950c10"}


def test_valid_continuity_is_detached_and_safe_integer_bounded():
    value = deepcopy(PAYLOAD)
    result = validate_continuity_payload(value)
    assert result == PAYLOAD and result is not value
    result["expected_revision"] = 4
    assert value == PAYLOAD
    assert validate_continuity_payload({**PAYLOAD, "expected_revision": 2**53 - 1})["expected_revision"] == 2**53 - 1


@pytest.mark.parametrize("value", [None, [], {}, {**PAYLOAD, "token": "private"},
    {**PAYLOAD, "version": True}, {**PAYLOAD, "version": "1"}, {**PAYLOAD, "version": 2},
    {**PAYLOAD, "expected_revision": True}, {**PAYLOAD, "expected_revision": 1.0},
    {**PAYLOAD, "expected_revision": 0}, {**PAYLOAD, "expected_revision": 2**53},
    {**PAYLOAD, "expected_revision": "3"}, {**PAYLOAD, "operation_id": "not-an-id"},
    {**PAYLOAD, "submission_id": PAYLOAD["submission_id"].upper()},
])
def test_untrusted_or_extra_payload_fields_are_denied(value):
    with pytest.raises(ValueError):
        validate_continuity_payload(value)
