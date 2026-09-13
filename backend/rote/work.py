"""Closed, bounded Work read-surface disposition; never an action authority."""

from copy import deepcopy
import json
from uuid import UUID


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


def validate_work_navigation(payload):
    """Accept only semantic list/detail/result navigation, with no side effects."""
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


def validate_work_components(components, supported_types=None):
    """Detach a closed complete view; never truncate data to fit a device.

    The 1 MiB/1024-node envelope accommodates the producer's maximum 100 rows
    with 4096-byte titles plus its 8192-byte evidence result and primitive
    wrappers. These are representation bounds, not source-retention authority.
    """
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
                _require(value["action"] == "chrome_open" and value["local"] is False)
                _require(type(value["disabled"]) is bool)
                validate_work_navigation(value["payload"])

        for component in components:
            node(component)
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise ValueError("work_surface_unavailable") from None
    return deepcopy(components)
