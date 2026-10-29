"""Validates closed server-issued Work continuity payloads shared by presentation, ROTE and Windows transport."""

from copy import deepcopy
from uuid import UUID

CONTINUITY_ACTION = "chrome_work_continuity"
_FIELDS = {"version", "operation_id", "expected_revision", "submission_id"}


def validate_continuity_payload(value):
    try:
        if (type(value) is not dict or set(value) != _FIELDS
                or type(value["version"]) is not int or value["version"] != 1
                or type(value["expected_revision"]) is not int
                or not 1 <= value["expected_revision"] <= 2**53 - 1):
            raise ValueError
        for name in ("operation_id", "submission_id"):
            identity = UUID(value[name])
            if identity.version != 4 or str(identity) != value[name]:
                raise ValueError
        return deepcopy(value)
    except (ValueError, TypeError, AttributeError):
        raise ValueError("work_continuity_invalid") from None
