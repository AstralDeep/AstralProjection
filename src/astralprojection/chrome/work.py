"""Pure Work list, detail and retained-result presentation (088 T010 subset).

The host authorizes every snapshot. ``build_work_view`` accepts ``mode``
(list/detail/result), ``status`` (ready/loading/unavailable), ``page`` containing
the WorkService.list envelope, ``operation`` containing its public metadata, and
``result`` containing WorkService.result's identity/revision/result envelope.
No raw assignment, checkpoint, claims, credential or diagnostic is forwarded.

Buttons emit only ``chrome_open`` for surface ``work`` with closed params
``mode``, optional ``operation_id`` or ``after_id``. They neither submit nor
control work. The host must register and authorize those reads, discard stale
owner deliveries and supply a matching operation/result revision. All layouts
preserve the same evidence. Watch delivery/consumption remains a separate host
and client integration; this pure builder does not establish that connection.

The host has already verified retained receipts; structural checks here do not
authenticate provenance. URLs are escaped source text, not navigation actions.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime, timedelta
import json
import re
from urllib.parse import urlsplit
from uuid import UUID

from webrender.renderer import safe_url

from astralprojection.models import ChromeViewModel, LayoutView, ThemeView

from ._components import alert, badge, build_view, button, card, key_value, text

_STATES = {
    "queued": "Queued",
    "active": "In progress",
    "awaiting_approval": "Review required",
    "awaiting_authority": "Authorization required",
    "budget_blocked": "Budget limit reached",
    "reconciliation_required": "Outcome uncertain",
    "paused": "Paused",
    "awaiting_event": "Waiting for an event",
    "retry_eligible": "Retry eligible",
    "completed": "Completed",
    "failed": "Failed",
    "cancelled": "Cancelled",
    "unsupported_version": "Unsupported version",
}
_RESULT_REASONS = {
    "unsupported": "This result format is not supported.",
    "not_completed": "Work has not completed. A retained result is not available yet.",
    "not_retained": "Source content was not retained for this work.",
    "unavailable": "The retained result is unavailable. Refresh to check its current state.",
}
_PROFILES = {
    "text/html": ("html_readable_v1", "HTML readable text"),
    "application/xhtml+xml": ("html_readable_v1", "HTML readable text"),
    "text/plain": ("plain_text_v1", "Plain text"),
}
_FLAGS = ("body_complete", "extraction_complete", "excerpt_complete", "redacted")
_SOURCE_KEYS = {
    *_FLAGS,
    "requested_url",
    "final_url",
    "retrieved_at",
    "media_type",
    "extraction_profile",
    "title",
    "action_id",
    "result_digest",
    "revision_digest",
}
_METRICS = {
    "model_calls": "Model calls",
    "tool_calls": "Tool calls",
    "tokens": "Tokens",
    "elapsed_ms": "Elapsed time (ms)",
    "spend_micro_units": "Monetary cost",
}
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
# The closed one_page_excerpts v1 producer's canonical UTF-8 result budget.
# Presentation framing is additional and must not be charged to this input cap.
_RESULT_BYTES = 8192


def _require(condition):
    if not condition:
        raise ValueError("work_view_unavailable")


def _keys(value, expected):
    _require(isinstance(value, Mapping) and set(value) == expected)


def _string(value, maximum=4096, *, empty=False):
    _require(type(value) is str)
    _require(
        (empty or bool(value))
        and len(value) <= maximum
        and len(value.encode("utf-8")) <= maximum
        and _CONTROL.search(value) is None
    )
    return value


def _identity(value):
    _string(value, 36)
    identity = UUID(value)
    _require(identity.version == 4 and str(identity) == value)
    return value


def _integer(value, minimum=1):
    _require(type(value) is int and minimum <= value <= 2**63 - 1)
    return value


def _time(value, *, optional=False):
    if optional and value is None:
        return None
    parsed = datetime.fromisoformat(_string(value, 48).replace("Z", "+00:00"))
    _require(parsed.utcoffset() == timedelta(0))
    return value


def _url(value):
    # Reuse renderer scheme sanitization. These additional shape checks describe
    # absolute source metadata, not a second public-egress or fetch policy.
    value = _string(value, 8192)
    _require(safe_url(value) == value and not any(char.isspace() for char in value))
    parsed = urlsplit(value)
    _require(
        parsed.scheme in {"http", "https"}
        and parsed.hostname
        and parsed.username is None
        and parsed.password is None
    )
    _require(parsed.port is None or 1 <= parsed.port <= 65535)
    return value


def _operation(value):
    """Select only the public read model; private extension fields stay opaque."""
    _require(isinstance(value, Mapping))
    result = {
        "id": _identity(value.get("id")),
        "revision": _integer(value.get("revision")),
        "title": _string(value.get("title")),
        "disposition": value.get("disposition"),
        "kind": value.get("kind"),
        "schema_supported": value.get("schema_supported"),
    }
    _require(type(result["disposition"]) is str and result["disposition"] in _STATES)
    _require(bool(result["title"].strip()))
    _require(
        result["kind"] in (None, "chat", "research") and type(result["schema_supported"]) is bool
    )
    for name in ("instruction_revision", "control_epoch"):
        _integer(value.get(name))
    for name in ("created_at", "updated_at", "next_wake_at", "deadline_at"):
        result[name] = _time(value.get(name), optional=name in {"next_wake_at", "deadline_at"})
    usage = value.get("usage")
    _require(isinstance(usage, Mapping))
    result["usage"] = {}
    for bucket in ("spent", "daily", "outstanding"):
        if bucket not in usage:
            continue
        _require(isinstance(usage[bucket], Mapping))
        result["usage"][bucket] = {
            name: None if amount is None else _integer(amount, 0)
            for name, amount in usage[bucket].items()
            if name in _METRICS
        }
    return result


def _open(label, mode, **params):
    return button(label, "chrome_open", {"surface": "work", "params": {"mode": mode, **params}})


def _list(page):
    """Keep the exact stable continuation and distinguish bad pages from empty."""
    _keys(page, {"operations", "next_cursor", "page_full"})
    values = page["operations"]
    _require(
        isinstance(values, (list, tuple)) and len(values) <= 100 and type(page["page_full"]) is bool
    )
    rows = [_operation(value) for value in values]
    identities = [row["id"] for row in rows]
    _require(identities == sorted(set(identities)))
    cursor = page["next_cursor"]
    if page["page_full"]:
        _require(bool(rows) and _identity(cursor) == rows[-1]["id"])
    else:
        _require(cursor is None)
    components = [
        card(
            row["title"],
            [
                badge(_STATES[row["disposition"]]),
                _open("View task", "detail", operation_id=row["id"]),
            ],
        )
        for row in rows
    ]
    if not rows:
        components.append(text("No work yet."))
    if cursor is not None:
        components.append(_open("More work", "list", after_id=cursor))
    components.append(_open("Refresh", "list"))
    return components


def _detail(row):
    """Show public lifecycle/usage facts without synthesizing effect controls."""
    components = [
        badge(_STATES[row["disposition"]]),
        _open("View result", "result", operation_id=row["id"]),
    ]
    components.append(
        key_value(
            [
                (label, row[name] or "Not scheduled")
                for name, label in (
                    ("created_at", "Created"),
                    ("updated_at", "Updated"),
                    ("next_wake_at", "Next activity"),
                    ("deadline_at", "Deadline"),
                )
            ]
        )
    )
    pairs = []
    for bucket, prefix in (
        ("spent", "Used"),
        ("daily", "Daily used"),
        ("outstanding", "Outstanding"),
    ):
        for name, amount in row["usage"].get(bucket, {}).items():
            display = "Unknown" if amount is None else str(amount)
            if name == "spend_micro_units" and amount is not None:
                display = f"{amount} micro-units (currency unavailable)"
            pairs.append((f"{prefix}: {_METRICS[name]}", display))
    components.append(
        key_value(pairs, title="Usage") if pairs else text("Usage not recorded.", "caption")
    )
    return components


def _content(value):
    """Validate the full bounded excerpt envelope before rendering any passage."""
    _keys(value, {"version", "scope", "disposition", "source", "passages"})
    _require(
        type(value["version"]) is int
        and value["version"] == 1
        and value["scope"] == "one_page_excerpts"
    )
    source = value["source"]
    _keys(source, _SOURCE_KEYS)
    _require(all(type(source[name]) is bool for name in _FLAGS))
    selected = {name: source[name] for name in _FLAGS}
    selected.update({name: _url(source[name]) for name in ("requested_url", "final_url")})
    selected.update(
        title=_string(source["title"], 512, empty=True),
        retrieved_at=_time(source["retrieved_at"]),
        action_id=_identity(source["action_id"]),
    )
    for name in ("media_type", "extraction_profile", "result_digest", "revision_digest"):
        selected[name] = _string(source[name], 128)
    _require(
        selected["media_type"] in _PROFILES
        and _PROFILES[selected["media_type"]][0] == selected["extraction_profile"]
    )
    for name in ("result_digest", "revision_digest"):
        _require(re.fullmatch(r"[0-9a-f]{64}", selected[name]) is not None)
    raw = value["passages"]
    _require(isinstance(raw, (list, tuple)) and len(raw) <= 8)
    passages = []
    for item in raw:
        _keys(item, {"id", "text"})
        identity = _string(item["id"], 4)
        _require(re.fullmatch(r"p[0-9]{3}", identity) is not None and identity != "p000")
        content = _string(item["text"], 2048)
        _require(len(content) <= 512)
        passages.append({"id": identity, "text": content})
    _require(len({item["id"] for item in passages}) == len(passages))
    disposition = "evidence" if passages else "insufficient_evidence"
    _require(value["disposition"] == disposition)
    checked = {
        "version": 1,
        "scope": "one_page_excerpts",
        "disposition": disposition,
        "source": selected,
        "passages": passages,
    }
    _require(
        len(
            json.dumps(checked, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
        )
        <= _RESULT_BYTES
    )
    return checked


def _result(envelope, row):
    """Bind displayed content to its public task revision before any rendering."""
    _keys(envelope, {"id", "revision", "result"})
    _require(
        _identity(envelope["id"]) == row["id"] and _integer(envelope["revision"]) == row["revision"]
    )
    result = envelope["result"]
    _keys(result, {"version", "available", "reason", "content"})
    _require(
        type(result["version"]) is int
        and result["version"] == 1
        and type(result["available"]) is bool
    )
    if not result["available"]:
        _require(
            result["content"] is None
            and type(result["reason"]) is str
            and result["reason"] in _RESULT_REASONS
        )
        return [alert(_RESULT_REASONS[result["reason"]], "info")]
    _require(
        result["reason"] is None
        and row["schema_supported"]
        and row["kind"] == "research"
        and row["disposition"] == "completed"
    )
    content = _content(result["content"])
    source = content["source"]
    components = [text("Selected excerpts", "h3")]
    if not content["passages"]:
        components.append(
            alert("Insufficient evidence. No passages were selected from this source.", "info")
        )
    components.extend(text(passage["text"]) for passage in content["passages"])
    components.append(
        text("Selected source text, not a summary of the full visual page.", "caption")
    )
    components.append(
        card(
            source["title"] or "Source",
            [
                key_value(
                    [
                        ("Requested URL", source["requested_url"]),
                        ("Retrieved URL", source["final_url"]),
                        ("Retrieved at", source["retrieved_at"]),
                        ("Extraction", _PROFILES[source["media_type"]][1]),
                    ]
                )
            ],
        )
    )
    components.append(
        key_value(
            [
                (
                    "Response body",
                    "Response body complete"
                    if source["body_complete"]
                    else "Response body incomplete",
                ),
                (
                    "Text extraction",
                    "Extraction complete for this extractor"
                    if source["extraction_complete"]
                    else "Extraction incomplete",
                ),
                (
                    "Retained text",
                    "Bounded extracted text retained"
                    if source["excerpt_complete"]
                    else "Retained text incomplete",
                ),
                (
                    "Redaction",
                    "Content was redacted" if source["redacted"] else "No redaction reported",
                ),
            ],
            title="Completeness",
        )
    )
    return components


def build_work_view(
    state: Mapping[str, object],
    *,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Render authorized public Work snapshots; malformed content is unavailable.

    No partial oversized result is displayed and no client-layout mode shortens
    selected evidence. Unknown host fields are never serialized or displayed.
    """
    title = "Recent work"
    try:
        _require(isinstance(state, Mapping))
        mode, status = state.get("mode"), state.get("status")
        _require(
            mode in ("list", "detail", "result") and status in ("ready", "loading", "unavailable")
        )
        if status == "loading":
            components = [alert("Loading work…", "info")]
        elif status == "unavailable":
            components = [
                alert("Work is unavailable. Refresh to check its current state.", "info"),
                _open("Refresh", "list"),
            ]
        elif mode == "list":
            components = _list(state.get("page"))
        else:
            row = _operation(state.get("operation"))
            title = row["title"]
            components = _detail(row) if mode == "detail" else _result(state.get("result"), row)
            components.extend(
                [
                    _open("Refresh", mode, operation_id=row["id"]),
                    _open("Back to recent work", "list"),
                ]
            )
    except (ValueError, TypeError, AttributeError, KeyError, OverflowError):
        title = "Recent work"
        components = [
            alert("This Work view is unavailable. Refresh to check its current state.", "warning"),
            _open("Refresh", "list"),
        ]
    return build_view("work", title, components, theme=theme, layout=layout)
