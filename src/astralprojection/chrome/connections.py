"""Pure owner-facing framework credential views (feature 088 T048 projection half).

A framework credential lets the owner's own tooling reach their Work through the
framework ingress. The credential itself is the authority, so this module is
deliberately narrow:

* ``build_connections_view`` renders the owner's already-authorized credential
  rows -- the non-secret key prefix, the granted scopes, expiry, how many
  admissions have been consumed out of the allowance, and whether the row is
  revoked, expired or exhausted -- plus the issue form and, for a live row, the
  revoke command carrying the exact ``credential_id`` and ``expected_revision``
  the host issued. **No plaintext secret is an input to this builder**, so a
  listing can never re-disclose one, not on first render and not on any
  re-render, reconnect or navigation replay.
* ``build_issued_secret_view`` is the one dedicated view that shows a freshly
  issued secret, and it shows it exactly once, in one component, together with
  the warning that it cannot be shown again. It refuses a secret that is not the
  one belonging to the row it was handed, so a stale pairing cannot be displayed
  as if it were current.

Every field is validated against an exact closed key set: an unknown or
malformed row is refused as unavailable rather than rendered partially. The host
authorizes and authenticates; this builder invents no authority, offers no
action beyond the two server-issued commands, and computes no expiry clock of
its own (``expired`` is the host's decision against server time).
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping

from astralprojection.models import ChromeViewModel, ComponentView, LayoutView, ThemeView

from ._components import (
    alert,
    badge,
    build_view,
    button,
    card,
    denied_view,
    field,
    form,
    key_value,
    text,
    unavailable_view,
)

SURFACE = "connections"
TITLE = "Connections"
ISSUE_ACTION = "chrome_connection_issue"
REVOKE_ACTION = "chrome_connection_revoke"

_ROW_KEYS = {
    "credential_id",
    "revision",
    "name",
    "prefix",
    "scopes",
    "created_at",
    "expires_at",
    "consumed_admissions",
    "max_admissions",
    "revoked",
    "expired",
}
_FORM_KEYS = {"scope_options", "defaults", "error"}
_DEFAULT_KEYS = {"name", "scopes", "expires_in_seconds", "max_admissions"}
_IDENTITY_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
_SCOPE_RE = re.compile(r"[a-z][a-z0-9_.:-]{0,63}")
_PREFIX_RE = re.compile(r"[A-Za-z0-9_-]{4,32}")
_SECRET_RE = re.compile(r"[A-Za-z0-9_-]{16,256}")
_NAME_MAX = 128
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _require(condition: object) -> None:
    if not condition:
        raise ValueError("connections_view_unavailable")


def _string(value: object, maximum: int, *, empty: bool = False) -> str:
    _require(type(value) is str)
    _require(
        (empty or bool(value))
        and len(value) <= maximum
        and _CONTROL_RE.search(value) is None  # type: ignore[arg-type]
    )
    return value  # type: ignore[return-value]


def _count(value: object, minimum: int = 0) -> int:
    _require(type(value) is int and minimum <= value <= 2**53 - 1)
    return value  # type: ignore[return-value]


def _row(value: object) -> dict[str, object]:
    """Accept exactly the public credential record; anything else is refused."""
    _require(isinstance(value, Mapping) and set(value) == _ROW_KEYS)  # type: ignore[arg-type]
    row = dict(value)  # type: ignore[arg-type]
    _require(_IDENTITY_RE.fullmatch(_string(row["credential_id"], 36)) is not None)
    _count(row["revision"], 1)
    _string(row["name"], _NAME_MAX)
    _require(bool(str(row["name"]).strip()))
    _require(_PREFIX_RE.fullmatch(_string(row["prefix"], 32)) is not None)
    scopes = row["scopes"]
    _require(isinstance(scopes, (list, tuple)) and len(scopes) <= 32)
    for scope in scopes:  # type: ignore[union-attr]
        _require(_SCOPE_RE.fullmatch(_string(scope, 64)) is not None)
    _require(list(scopes) == sorted(set(scopes)))  # type: ignore[arg-type]
    _string(row["created_at"], 48)
    if row["expires_at"] is not None:
        _string(row["expires_at"], 48)
    _count(row["consumed_admissions"])
    _count(row["max_admissions"], 1)
    _require(row["consumed_admissions"] <= row["max_admissions"])  # type: ignore[operator]
    for name in ("revoked", "expired"):
        _require(type(row[name]) is bool)
    return row


def _row_badge(row: Mapping[str, object]) -> ComponentView:
    """One honest state per row; a revoked row is never shown as merely used up."""
    if row["revoked"]:
        return badge("Revoked", "error")
    if row["expired"]:
        return badge("Expired", "warning")
    if row["consumed_admissions"] >= row["max_admissions"]:  # type: ignore[operator]
        return badge("Allowance used up", "warning")
    return badge("Active", "success")


def _usable(row: Mapping[str, object]) -> bool:
    return not row["revoked"] and not row["expired"]


def _row_card(row: Mapping[str, object]) -> ComponentView:
    children: list[ComponentView] = [
        _row_badge(row),
        key_value(
            [
                ("Key prefix", row["prefix"]),
                ("Scopes", ", ".join(row["scopes"]) or "No scopes"),  # type: ignore[arg-type]
                ("Created", row["created_at"]),
                ("Expires", row["expires_at"] or "No expiry recorded"),
                (
                    "Admissions used",
                    f"{row['consumed_admissions']} of {row['max_admissions']}",
                ),
            ]
        ),
    ]
    if _usable(row):
        children.append(
            button(
                "Revoke this key",
                REVOKE_ACTION,
                {
                    "version": 1,
                    "credential_id": row["credential_id"],
                    "expected_revision": row["revision"],
                },
                variant="danger",
            )
        )
    else:
        children.append(text("This key can no longer be used.", "caption"))
    return card(row["name"], children)


def _issue_form(form_state: object) -> list[ComponentView]:
    """Offer issuance only with the host's own closed scope vocabulary."""
    if form_state is None:
        return []
    _require(isinstance(form_state, Mapping) and set(form_state) == _FORM_KEYS)  # type: ignore[arg-type]
    options = form_state["scope_options"]  # type: ignore[index]
    _require(isinstance(options, (list, tuple)) and 1 <= len(options) <= 32)
    for scope in options:  # type: ignore[union-attr]
        _require(_SCOPE_RE.fullmatch(_string(scope, 64)) is not None)
    _require(list(options) == sorted(set(options)))  # type: ignore[arg-type]
    defaults = form_state["defaults"]  # type: ignore[index]
    _require(isinstance(defaults, Mapping) and set(defaults) == _DEFAULT_KEYS)  # type: ignore[arg-type]
    _string(defaults["name"], _NAME_MAX, empty=True)  # type: ignore[index]
    selected = defaults["scopes"]  # type: ignore[index]
    _require(isinstance(selected, (list, tuple)) and set(selected) <= set(options))  # type: ignore[arg-type]
    _count(defaults["expires_in_seconds"], 1)  # type: ignore[index]
    _count(defaults["max_admissions"], 1)  # type: ignore[index]
    components: list[ComponentView] = []
    failure = form_state["error"]  # type: ignore[index]
    if failure is not None:
        components.append(alert(_string(failure, 512), "error"))
    components.append(
        form(
            [
                field("name", "Name this key", default=defaults["name"]),  # type: ignore[index]
                field(
                    "scopes",
                    "What it may do",
                    "checklist",
                    default=list(selected),
                    options=list(options),
                ),
                field(
                    "expires_in_seconds",
                    "Expires in (seconds)",
                    "number",
                    default=defaults["expires_in_seconds"],  # type: ignore[index]
                ),
                field(
                    "max_admissions",
                    "Maximum admissions",
                    "number",
                    default=defaults["max_admissions"],  # type: ignore[index]
                ),
            ],
            title="Issue a new key",
            description=(
                "The key is shown once, immediately after it is issued. Keep it somewhere safe; "
                "it cannot be shown again."
            ),
            submit_action=ISSUE_ACTION,
            submit_label="Issue key",
            submit_payload={"version": 1},
        )
    )
    return components


def build_connections_view(
    rows: Iterable[Mapping[str, object]] = (),
    form_state: Mapping[str, object] | None = None,
    *,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the owner's credential list; no plaintext secret can reach it."""
    if denied:
        return denied_view(SURFACE, TITLE, "You are not allowed to view these connections.")
    if error:
        return unavailable_view(SURFACE, TITLE, error)
    try:
        _require(not isinstance(rows, Mapping))
        records = [_row(item) for item in rows]
        identities = [record["credential_id"] for record in records]
        _require(len(identities) == len(set(identities)) and len(identities) <= 100)
        components: list[ComponentView] = [
            text(
                "Keys let your own tools reach your work. Each key carries only the permissions "
                "you grant it and can be revoked at any time.",
                "body",
            )
        ]
        components.extend(_issue_form(form_state))
        if not records:
            components.append(alert("You have not issued any keys yet.", "info"))
        components.extend(_row_card(record) for record in records)
        return build_view(SURFACE, TITLE, components, theme=theme, layout=layout)
    except (ValueError, TypeError, AttributeError, KeyError, OverflowError):
        return unavailable_view(
            SURFACE, TITLE, "These connections are unavailable. Reopen Connections to try again."
        )


def build_issued_secret_view(
    secret: object,
    view: Mapping[str, object],
    *,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Show one freshly issued secret exactly once, bound to its own record."""
    try:
        row = _row(view)
        _require(_SECRET_RE.fullmatch(_string(secret, 256)) is not None)
        _require(str(secret).startswith(str(row["prefix"])))
        _require(_usable(row) and row["consumed_admissions"] == 0)
        components: list[ComponentView] = [
            alert(
                "This key is shown once, right now. Copy it before you leave this view -- it "
                "cannot be shown again, and a lost key must be revoked and reissued.",
                "warning",
            ),
            key_value([("Key", secret)], title="Your new key"),
            key_value(
                [
                    ("Name", row["name"]),
                    ("Key prefix", row["prefix"]),
                    ("Scopes", ", ".join(row["scopes"]) or "No scopes"),  # type: ignore[arg-type]
                    ("Expires", row["expires_at"] or "No expiry recorded"),
                    ("Maximum admissions", row["max_admissions"]),
                ],
                title="What this key can do",
            ),
            button(
                "Back to Connections",
                "chrome_open",
                {"surface": SURFACE, "params": {}},
            ),
        ]
        return build_view(SURFACE, TITLE, components, theme=theme, layout=layout)
    except (ValueError, TypeError, AttributeError, KeyError, OverflowError):
        # The refusal deliberately carries no part of the secret or the record.
        return unavailable_view(
            SURFACE,
            TITLE,
            "This key cannot be shown. Reopen Connections and issue a new key if you need one.",
        )


__all__ = [
    "ISSUE_ACTION",
    "REVOKE_ACTION",
    "SURFACE",
    "TITLE",
    "build_connections_view",
    "build_issued_secret_view",
]
