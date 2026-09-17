"""Pure Work list, detail and retained-result presentation (088 T010 subset).

The host authorizes every snapshot. ``build_work_view`` accepts ``mode``
(list/detail/result), ``status`` (ready/loading/unavailable), ``page`` containing
the WorkService.list envelope, ``operation`` containing its public metadata, and
``result`` containing WorkService.result's identity/revision/result envelope.
No raw assignment, checkpoint, claims, credential or diagnostic is forwarded.

Buttons emit ``chrome_open`` for surface ``work`` with closed params ``mode``,
optional ``operation_id`` or ``after_id``. They neither submit nor control work.
The host must register and authorize those reads, discard stale owner deliveries
and supply a matching operation/result revision. All layouts preserve the same
evidence. Watch delivery/consumption remains a separate host and client
integration; this pure builder does not establish that connection.

Feature 088 T043 adds the one closed non-navigation action, ``chrome_work_result_save``.
A result view whose host supplies ``save`` (server-issued propose bindings:
``submission_id``, ``publication_id``, ``expected_revision``, ``conversation_id``,
``conversation_title``, ``expected_workspace_revision``,
``expected_workspace_publication_id``) renders a **Save result** button that
carries exactly those bindings as the ``propose`` step. Mode ``review`` renders
Deep's review body (``review``: the exact ``result_publication`` proposal and the
complete component to be saved) with a destination, expiry and, when the host
supplies ``approve`` (``submission_id``, ``expired``), the ``save`` step bound to
the proposal digest. Viewing never saves; the client invents no authority and
Deep re-verifies every binding before any publication.

Feature 088 T052 adds the owner's measurement and charge-basis disclosure. The
detail mode renders ``usage.basis`` (per usage dimension: observed/estimated/
uncertain/none) as explicit badges, quotes ``usage.currency`` when the host
reports one instead of claiming the currency is unavailable, and renders the
host's optional ``measurements`` read model (logical task attempts vs physical
claims, observed interval sums vs elapsed, ``incomplete``/``cutoff``). Every one
of those fields is optional and additive: a snapshot without them renders exactly
as before. A missing amount is "Unknown" and is never shown as zero, no attempt
count is synthesized when the host supplies none, and an unrecognized basis token
makes the view unavailable rather than rendering an unknown basis as a known one.

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

SAVE_ACTION = "chrome_work_result_save"
_SAVE_KEYS = {
    "submission_id", "publication_id", "expected_revision", "conversation_id",
    "conversation_title", "expected_workspace_revision", "expected_workspace_publication_id",
}
_REVIEW_KEYS = {"version", "status", "created", "revision", "proposal", "component"}
_PROPOSAL_KEYS = {
    "action_id", "proposal_digest", "publication_id", "conversation_id", "component_id",
    "base_render_revision", "base_publication_id", "content_digest", "stage_digest", "expires_at",
}
_COMPONENT_KEYS = {"component_id", "component_type", "title", "position", "payload"}
_APPROVE_KEYS = {"submission_id", "expired"}
_COMPONENT_PREFIX = "au_work_result_"
# Deep's result_component is one astralprims Card of the proven public excerpt:
# text passages/captions plus one source KeyValue. Anything else is not reviewable.
_REVIEW_BYTES = 16384

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
# Feature 088 T052: the closed charge-basis vocabulary shared with Plane's
# additive usage annotation. "none" means the dimension is not charged at all --
# it is not a zero amount, and neither is a missing amount.
_BASIS = {
    "observed": ("Observed", "success"),
    "estimated": ("Estimated", "info"),
    "uncertain": ("Uncertain", "warning"),
    "none": ("Not charged", "default"),
}
_MEASUREMENT_KEYS = {
    "version",
    "logical_attempts",
    "physical_claims",
    "observed_interval_ms",
    "elapsed_ms",
    "incomplete",
    "cutoff",
}
_CURRENCY = re.compile(r"[A-Z][A-Z0-9]{2,7}")
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
    result["usage_basis"] = _basis(usage.get("basis"))
    result["currency"] = _currency(usage.get("currency"))
    return result


def _basis(value):
    """Keep only known dimensions; an unknown basis token is not displayable."""
    if value is None:
        return {}
    _require(isinstance(value, Mapping))
    selected = {}
    for name, token in value.items():
        if name not in _METRICS:
            continue
        _require(type(token) is str and token in _BASIS)
        selected[name] = token
    return selected


def _currency(value):
    """Quote the host's reported currency; absence stays honestly unavailable."""
    if value is None:
        return None
    _require(_CURRENCY.fullmatch(_string(value, 8)) is not None)
    return value


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


def _measurements(value):
    """Disclose recorded timing exactly; nothing is inferred for an old task."""
    _keys(value, _MEASUREMENT_KEYS)
    _require(type(value["version"]) is int and value["version"] == 1)
    logical = _integer(value["logical_attempts"], 0)
    physical = _integer(value["physical_claims"], 0)
    _require(type(value["incomplete"]) is bool and type(value["cutoff"]) is bool)
    observed, elapsed = value["observed_interval_ms"], value["elapsed_ms"]
    for amount in (observed, elapsed):
        if amount is not None:
            _integer(amount, 0)
    components = [
        key_value(
            [
                ("Attempts (this task)", str(logical)),
                ("Runs recorded (claims)", str(physical)),
                ("Observed activity (ms)", "Unknown" if observed is None else str(observed)),
                ("Elapsed since start (ms)", "Unknown" if elapsed is None else str(elapsed)),
            ],
            title="Timing",
        )
    ]
    if logical != physical:
        components.append(
            text(
                "One task can be claimed and run more than once. These are the task and its "
                "recorded runs, not two different tasks.",
                "caption",
            )
        )
    if observed is not None and elapsed is not None:
        components.append(
            text(
                "Observed activity is the sum of recorded working intervals; elapsed time also "
                "includes waiting.",
                "caption",
            )
        )
    if value["incomplete"]:
        components.append(
            text("Some activity was not recorded. Observed activity is a lower bound.", "caption")
        )
    if value["cutoff"]:
        components.append(
            text(
                "Measurement stopped at the recorded window. Later activity is not included.",
                "caption",
            )
        )
    return components


def _basis_disclosure(basis):
    """Name how each shown amount was arrived at; never imply a measured charge."""
    return [
        card(
            "Charge basis",
            [
                *(
                    badge(f"{_METRICS[name]}: {_BASIS[basis[name]][0]}", _BASIS[basis[name]][1])
                    for name in sorted(basis)
                ),
                text(
                    "Estimated or uncertain amounts are not measured charges. A dimension that "
                    "is not charged is not a zero charge.",
                    "caption",
                ),
            ],
        )
    ]


def _detail(row, measurements=None):
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
                quoted = row["currency"] or "currency unavailable"
                display = f"{amount} micro-units ({quoted})"
            pairs.append((f"{prefix}: {_METRICS[name]}", display))
    components.append(
        key_value(pairs, title="Usage") if pairs else text("Usage not recorded.", "caption")
    )
    if row["usage_basis"]:
        components.extend(_basis_disclosure(row["usage_basis"]))
    if measurements is not None:
        components.extend(_measurements(measurements))
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


def _digest(value):
    _string(value, 64)
    _require(re.fullmatch(r"[0-9a-f]{64}", value) is not None)
    return value


def _destination(value):
    value = _string(value, 512)
    _require(value == value.strip() and value.isprintable())
    return value


def _head(revision, head):
    """A destination head is revision 0 with no publication, or both present."""
    _integer(revision, 0)
    _require(revision <= 2**53 - 1)
    if revision == 0:
        _require(head is None)
    else:
        _identity(head)


def _save(value, row, available):
    """Validate server-issued propose bindings against the displayed result."""
    _keys(value, _SAVE_KEYS)
    _require(available is True)
    for name in ("submission_id", "publication_id"):
        _identity(value[name])
    _require(value["submission_id"] != value["publication_id"])
    _require(_integer(value["expected_revision"]) == row["revision"])
    destination = _destination(value["conversation_id"])
    title = _string(value["conversation_title"], 512, empty=True)
    _head(value["expected_workspace_revision"], value["expected_workspace_publication_id"])
    payload = {"version": 1, "command": "propose", "operation_id": row["id"]}
    payload.update((name, value[name]) for name in sorted(_SAVE_KEYS) if name != "conversation_title")
    return [
        card(
            "Save this result",
            [
                text(
                    "Saving is a separate review of the exact content and destination. "
                    "Viewing this result does not save it.",
                    "caption",
                ),
                key_value([("Destination", title or destination)]),
                button("Save result", SAVE_ACTION, payload, variant="primary"),
            ],
        )
    ]


def _reviewed_card(payload, title):
    """Re-emit the exact reviewed card; an unknown shape is not partially shown."""
    _keys(payload, {"type", "title", "content", "variant"})
    _require(payload["type"] == "card" and payload["variant"] == "default")
    _require(_string(payload["title"], 4096) == title)
    raw = payload["content"]
    _require(isinstance(raw, (list, tuple)) and 1 <= len(raw) <= 16)
    children = []
    for item in raw:
        _require(isinstance(item, Mapping))
        if item.get("type") == "text":
            _keys(item, {"type", "content", "variant"})
            _require(item["variant"] in ("body", "caption"))
            children.append(text(_string(item["content"], 2048), item["variant"]))
        else:
            _require(item.get("type") == "keyvalue")
            _require({"type", "title", "items"} <= set(item) <= {"type", "title", "items", "columns"})
            if "columns" in item:
                _require(type(item["columns"]) is int and 1 <= item["columns"] <= 4)
            items = item["items"]
            _require(isinstance(items, (list, tuple)) and 1 <= len(items) <= 8)
            pairs = []
            for entry in items:
                _keys(entry, {"label", "value"})
                pairs.append((_string(entry["label"], 128), _string(entry["value"], 8192, empty=True)))
            children.append(key_value(pairs, title=_string(item["title"], 512, empty=True)))
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    _require(len(encoded.encode("utf-8")) <= _REVIEW_BYTES)
    return card(title, children)


def _review(value, row, approve, conversation_title):
    """Render Deep's exact review body; the approval carries only server bindings."""
    _keys(value, _REVIEW_KEYS)
    _require(type(value["version"]) is int and value["version"] == 1)
    _require(value["status"] == "review_required" and type(value["created"]) is bool)
    _require(_integer(value["revision"]) == row["revision"])
    proposal, component = value["proposal"], value["component"]
    _keys(proposal, _PROPOSAL_KEYS)
    _keys(component, _COMPONENT_KEYS)
    action_id = _identity(proposal["action_id"])
    _identity(proposal["publication_id"])
    _require(action_id != proposal["publication_id"])
    digest = _digest(proposal["proposal_digest"])
    for name in ("content_digest", "stage_digest"):
        _digest(proposal[name])
    destination = _destination(proposal["conversation_id"])
    _head(proposal["base_render_revision"], proposal["base_publication_id"])
    expires = _time(proposal["expires_at"])
    identity = _string(proposal["component_id"], 64)
    _require(identity == _COMPONENT_PREFIX + row["id"] and component["component_id"] == identity)
    _require(component["component_type"] == "card")
    title = _string(component["title"], 4096)
    _require(bool(title.strip()))
    _integer(component["position"], 0)
    reviewed = _reviewed_card(component["payload"], title)
    if conversation_title is not None:
        conversation_title = _string(conversation_title, 512, empty=True)
    components = [
        alert(
            "Review the exact content and destination. Nothing is saved until you approve it here.",
            "info",
        ),
        text("Exact content to be saved", "h3"),
        reviewed,
        key_value(
            [("Destination", conversation_title or destination), ("Review expires", expires)],
            title="Where it will be saved",
        ),
    ]
    if approve is None:
        components.append(
            text(
                "This proposal is not available for a decision. Reload the result and start "
                "Save result again.",
                "caption",
            )
        )
        return components
    _keys(approve, _APPROVE_KEYS)
    submission = _identity(approve["submission_id"])
    _require(type(approve["expired"]) is bool and submission != action_id)
    if approve["expired"]:
        components.append(
            alert(
                "This review expired before a decision. Open the result and start Save result "
                "again.",
                "warning",
            )
        )
        return components
    payload = {
        "version": 1,
        "command": "save",
        "operation_id": row["id"],
        "action_id": action_id,
        "submission_id": submission,
        "expected_revision": row["revision"],
        "proposal_digest": digest,
    }
    components.append(button("Save exactly this content", SAVE_ACTION, payload, variant="primary"))
    return components


def _result(envelope, row, save=None):
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
        _require(save is None)
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
    if save is not None:
        components.extend(_save(save, row, result["available"]))
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
            mode in ("list", "detail", "result", "review")
            and status in ("ready", "loading", "unavailable")
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
            if mode == "detail":
                components = _detail(row, state.get("measurements"))
            elif mode == "result":
                components = _result(state.get("result"), row, state.get("save"))
            else:
                components = _review(
                    state.get("review"), row, state.get("approve"), state.get("conversation_title")
                )
            components.extend(
                [
                    _open("Back to result", "result", operation_id=row["id"])
                    if mode == "review"
                    else _open("Refresh", mode, operation_id=row["id"]),
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
