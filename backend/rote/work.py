"""Closed, bounded validators for the Work read surface: only the exact two-step Save
command, with server-issued bindings Deep re-verifies, is admitted as a
non-navigation action; used by projection_surfaces/work.py and rote.adapter.
"""

from copy import deepcopy
import json
import re
from uuid import UUID

SAVE_ACTION = "chrome_work_result_save"
_DIGEST = re.compile(r"[0-9a-f]{64}")
_PROPOSE_FIELDS = frozenset(
    {
        "version", "command", "operation_id", "submission_id", "publication_id",
        "expected_revision", "conversation_id", "expected_workspace_revision",
        "expected_workspace_publication_id",
    }
)
_SAVE_FIELDS = frozenset(
    {"version", "command", "operation_id", "action_id", "submission_id", "expected_revision",
     "proposal_digest"}
)


def _require(value):
    if not value:
        raise ValueError("work_surface_unavailable")


def _identity(value):
    _require(type(value) is str)
    try:
        parsed = UUID(value)
    except ValueError:
        raise ValueError("work_surface_unavailable") from None
    _require(parsed.version == 4 and str(parsed) == value)


def _revision(value, minimum=1):
    _require(type(value) is int and minimum <= value <= 2**53 - 1)


def validate_work_save_command(payload):
    _require(type(payload) is dict and type(payload.get("version")) is int and payload["version"] == 1)
    command = payload.get("command")
    if command == "propose":
        _require(set(payload) == _PROPOSE_FIELDS)
        for name in ("operation_id", "submission_id", "publication_id"):
            _identity(payload[name])
        _require(payload["submission_id"] != payload["publication_id"])
        _revision(payload["expected_revision"])
        destination = payload["conversation_id"]
        _require(type(destination) is str and 1 <= len(destination) <= 512)
        _require(destination == destination.strip() and destination.isprintable())
        _revision(payload["expected_workspace_revision"], 0)
        head = payload["expected_workspace_publication_id"]
        if payload["expected_workspace_revision"] == 0:
            _require(head is None)
        else:
            _identity(head)
    else:
        _require(command == "save" and set(payload) == _SAVE_FIELDS)
        for name in ("operation_id", "action_id", "submission_id"):
            _identity(payload[name])
        _require(payload["action_id"] != payload["submission_id"])
        _revision(payload["expected_revision"])
        digest = payload["proposal_digest"]
        _require(type(digest) is str and _DIGEST.fullmatch(digest) is not None)


def validate_work_navigation(payload):
    _require(type(payload) is dict and set(payload) == {"surface", "params"})
    _require(payload["surface"] == "work")
    params = payload["params"]
    _require(type(params) is dict)
    mode = params.get("mode")
    if mode == "list":
        _require(set(params) in ({"mode"}, {"mode", "after_id"}))
        if "after_id" in params:
            _identity(params["after_id"])
    else:
        _require(mode in ("detail", "result") and set(params) == {"mode", "operation_id"})
        _identity(params["operation_id"])


# 1 MiB/1024 nodes sized for 100 rows plus 8 KiB evidence
def validate_work_components(components, supported_types=None):
    try:
        encoded = json.dumps(components, ensure_ascii=False, allow_nan=False).encode("utf-8")
        _require(type(components) is list and len(encoded) <= 1024 * 1024)
        count = 0

        def text(value):
            _require(type(value) is str and len(value.encode("utf-8")) <= 8192)

        def node(value, depth=0):
            nonlocal count
            count += 1
            _require(type(value) is dict and count <= 1024 and depth <= 8)
            kind = value.get("type")
            fields = {
                "text": ({"type", "content", "variant"}, set()),
                "alert": ({"type", "message", "variant"}, {"title"}),
                "badge": ({"type", "label", "variant"}, set()),
                "card": ({"type", "title", "content", "variant"}, set()),
                "keyvalue": ({"type", "items"}, {"title"}),
                "button": (
                    {"type", "label", "action", "payload", "variant", "disabled", "local"},
                    set(),
                ),
            }
            _require(type(kind) is str and kind in fields)
            _require(supported_types is None or kind in supported_types)
            required, optional = fields[kind]
            _require(required <= set(value) <= required | optional)
            for key in ("title", "message", "label", "variant"):
                if key in value:
                    text(value[key])
            if kind == "text":
                text(value["content"])
            elif kind == "card":
                _require(type(value["content"]) is list)
                for child in value["content"]:
                    node(child, depth + 1)
            elif kind == "keyvalue":
                _require(type(value["items"]) is list and len(value["items"]) <= 100)
                for item in value["items"]:
                    _require(type(item) is dict and set(item) == {"label", "value"})
                    text(item["label"])
                    text(item["value"])
            elif kind == "button":
                _require(value["local"] is False and type(value["disabled"]) is bool)
                if value["action"] == SAVE_ACTION:
                    validate_work_save_command(value["payload"])
                else:
                    _require(value["action"] == "chrome_open")
                    validate_work_navigation(value["payload"])

        for component in components:
            node(component)
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise ValueError("work_surface_unavailable") from None
    return deepcopy(components)
